require 'cloud/aws/stemcell_finder'
require 'uri'

module Bosh::AwsCloud
  class CloudV1
    include Bosh::CloudV1
    include Helpers

    API_VERSION = 1
    METADATA_TIMEOUT = 5 # in seconds
    DEVICE_POLL_TIMEOUT = 60 # in seconds

    attr_reader :ec2_resource
    attr_reader :registry
    attr_accessor :logger

    ##
    # Initialize BOSH AWS CPI. The contents of sub-hashes are defined in the {file:README.md}
    # @param [Hash] options CPI options
    # @option options [Hash] aws AWS specific options
    # @option options [Hash] agent agent options
    # @option options [Hash] registry agent options
    def initialize(options)
      @config = Bosh::AwsCloud::Config.build(options.dup.freeze)
      @logger = Bosh::Clouds::Config.logger
      request_id = options['aws']['request_id']
      if request_id
        @logger.set_request_id(request_id)
      end

      if @config.registry_configured?
        @registry = Bosh::Cpi::RegistryClient.new(
          @config.registry.endpoint,
          @config.registry.user,
          @config.registry.password
        )
      else
        @registry = Bosh::AwsCloud::RegistryDisabledClient.new
      end

      @aws_provider = Bosh::AwsCloud::AwsProvider.new(@config.aws, @logger)
      @ec2_client = @aws_provider.ec2_client
      @ec2_resource = @aws_provider.ec2_resource
      @az_selector = AvailabilityZoneSelector.new(@ec2_resource)
      @volume_manager = Bosh::AwsCloud::VolumeManager.new(@logger, @aws_provider)

      @cloud_core = CloudCore.new(@config, @logger, @volume_manager, @az_selector, API_VERSION)

      @instance_manager = InstanceManager.new(@ec2_resource, @logger)
      @instance_type_mapper = InstanceTypeMapper.new

      @props_factory = Bosh::AwsCloud::PropsFactory.new(@config)
    end

    ##
    # Reads current instance id from EC2 metadata. We are assuming
    # instance id cannot change while current process is running
    # and thus memoizing it.
    def current_vm_id
      return @current_vm_id if @current_vm_id

      http_client = HTTPClient.new
      http_client.connect_timeout = METADATA_TIMEOUT
      headers = {}

      response = http_client.put('http://169.254.169.254/latest/api/token', nil, { 'X-aws-ec2-metadata-token-ttl-seconds' => '300' })
      if response.status == 200
        headers['X-aws-ec2-metadata-token'] = response.body
      end

      response = http_client.get('http://169.254.169.254/latest/meta-data/instance-id/', nil, headers)
      unless response.status == 200
        cloud_error('Instance metadata endpoint returned ' \
                    "HTTP #{response.status}")
      end

      @current_vm_id = response.body
    rescue HTTPClient::TimeoutError
      cloud_error('Timed out reading instance metadata, ' \
                  'please make sure CPI is running on EC2 instance')
    end

    ##
    # Create an EC2 instance and wait until it's in running state
    def create_vm(agent_id, stemcell_id, vm_type, network_spec, disk_locality = [], environment = nil)
      raise Bosh::Clouds::CloudError, 'Cannot create VM without registry with CPI v1. Registry not configured.' unless @config.registry_configured?

      with_thread_name("create_vm(#{agent_id}, ...)") do
        network_props = @props_factory.network_props(network_spec)

        registry = { endpoint: @config.registry.endpoint }
        network_with_dns = network_props.dns_networks.first
        dns = { nameserver: network_with_dns.dns } unless network_with_dns.nil?
        registry_settings = AgentSettings.new(registry, network_props, dns)
        registry_settings.environment = environment
        registry_settings.agent_id = agent_id

        instance_id, = @cloud_core.create_vm(agent_id, stemcell_id, vm_type, network_props, registry_settings, disk_locality, environment) do |instance_id, settings|
          @registry.update_settings(instance_id, settings.agent_settings)
        end
        instance_id
      end
    end

    ##
    # Delete EC2 instance ("terminate" in AWS language) and wait until
    # it reports as terminated
    def delete_vm(instance_id)
      with_thread_name("delete_vm(#{instance_id})") do
        logger.info("Deleting instance '#{instance_id}'")

        @cloud_core.delete_vm(instance_id) do |delete_vm_instance_id|
          @registry.delete_settings(delete_vm_instance_id)
        end
      end
    end

    def reboot_vm(instance_id)
      with_thread_name("reboot_vm(#{instance_id})") do
        @instance_manager.find(instance_id).reboot
      end
    end

    def has_vm?(instance_id)
      with_thread_name("has_vm?(#{instance_id})") do
        @instance_manager.find(instance_id).exists?
      end
    end

    def set_vm_metadata(vm, metadata)
      metadata = Hash[metadata.map { |key, value| [key.to_s, value] }]

      instance = @ec2_resource.instance(vm)

      job = metadata['job']
      index = metadata['index']

      if metadata['name']
        metadata['Name'] = metadata.delete('name')
      elsif job && index
        metadata['Name'] = "#{job}/#{index}"
      elsif metadata['compiling']
        metadata['Name'] = "compiling/#{metadata['compiling']}"
      end

      begin
        TagManager.create_tags(instance, metadata)
      rescue Aws::EC2::Errors::TagLimitExceeded => e
        logger.error("could not tag #{instance.id}: #{e.message}")
      end

      get_volume_ids_for_vm(instance).each do |volume_id|
        begin
          TagManager.create_tags(@ec2_resource.volume(volume_id), metadata)
        rescue Aws::EC2::Errors::TagLimitExceeded => e
          logger.error("could not tag volume #{volume_id}: #{e.message}")
        end
      end
    rescue Aws::EC2::Errors::TagLimitExceeded => e
      logger.error("could not tag #{instance.id}: #{e.message}")
    end

    def create_disk(size, cloud_properties, instance_id = nil)
      raise ArgumentError, 'disk size needs to be an integer' unless size.is_a?(Integer)

      with_thread_name("create_disk(#{size}, #{instance_id})") do
        props = @props_factory.disk_props(cloud_properties)

        tag_list = TagManager.format_tags(props.tags)

        volume_properties = VolumeProperties.new(
          size: size,
          type: props.type,
          iops: props.iops,
          throughput: props.throughput,
          az: @az_selector.select_availability_zone(instance_id),
          encrypted: props.encrypted,
          kms_key_arn: props.kms_key_arn,
          tags: tag_list
        )
        volume = @volume_manager.create_ebs_volume(**volume_properties.persistent_disk_config)

        volume.id
      end
    end

    def has_disk?(disk_id)
      @cloud_core.has_disk?(disk_id)
    end

    def delete_disk(disk_id)
      with_thread_name("delete_disk(#{disk_id})") do
        volume = @ec2_resource.volume(disk_id)
        @volume_manager.delete_ebs_volume(volume, @config.aws.fast_path_delete?)
      end
    end

    def resize_disk(disk_id, new_size)
      with_thread_name("resize_disk(#{disk_id}, #{new_size})") do
        @cloud_core.resize_disk(disk_id, new_size)
      end
    end

    def attach_disk(instance_id, disk_id)
      with_thread_name("attach_disk(#{instance_id}, #{disk_id})") do
        _ = @cloud_core.attach_disk(instance_id, disk_id) do |instance, device_name|
          update_agent_settings(instance_id) do |settings|
            settings['disks'] ||= {}
            settings['disks']['persistent'] ||= {}
            settings['disks']['persistent'][disk_id] = BlockDeviceManager.device_path(device_name, instance.instance_type, disk_id, @cloud_core.instance_type_info)
          end
        end
      end
    end

    def detach_disk(instance_id, disk_id)
      with_thread_name("detach_disk(#{instance_id}, #{disk_id})") do
        @cloud_core.detach_disk(instance_id, disk_id) do |detach_disk_disk_id|
          update_agent_settings(instance_id) do |settings|
            settings['disks'] ||= {}
            settings['disks']['persistent'] ||= {}
            settings['disks']['persistent'].delete(detach_disk_disk_id)
          end
        end
      end
    end

    def get_disks(vm_id)
      get_volume_ids_for_vm(@ec2_resource.instance(vm_id))
    end

    def set_disk_metadata(disk_id, metadata)
      with_thread_name("set_disk_metadata(#{disk_id}, ...)") do
        begin
          volume = @ec2_resource.volume(disk_id)
          TagManager.create_tags(volume, metadata)
        rescue Aws::EC2::Errors::TagLimitExceeded => e
          logger.error("could not tag #{volume.id}: #{e.message}")
        end
      end
    end

    def snapshot_disk(disk_id, metadata)
      metadata = Hash[metadata.map { |key, value| [key.to_s, value] }]

      with_thread_name("snapshot_disk(#{disk_id})") do
        volume = @ec2_resource.volume(disk_id)
        devices = []
        volume.attachments.each { |attachment| devices << attachment.device }

        name = ['deployment', 'job', 'index'].collect { |key| metadata[key] }

        unless devices.empty?
          name << devices.first.split('/').last
          metadata['device'] = devices.first
        end

        description = name.join('/')

        metadata.merge!(
          'director' => metadata['director_name'],
          'instance_index' => metadata['index'].to_s,
          'instance_name' => metadata['job'] + '/' + metadata['instance_id'],
          'Name' => description
        )

        %w[director_name index job].each do |tag|
          metadata.delete(tag)
        end

        snapshot_opts = {
          description: description,
          tag_specifications: TagManager.tag_specifications_for_resources(metadata, ['snapshot']),
        }

        snapshot = volume.create_snapshot(snapshot_opts)
        logger.info("snapshot '#{snapshot.id}' of volume '#{disk_id}' created")

        ResourceWait.for_snapshot(snapshot: snapshot, state: 'completed')
        snapshot.id
      end
    end

    def delete_snapshot(snapshot_id)
      with_thread_name("delete_snapshot(#{snapshot_id})") do
        snapshot = @ec2_resource.snapshot(snapshot_id)
        begin
          snapshot.delete
        rescue Aws::EC2::Errors::InvalidSnapshotNotFound
          logger.info("snapshot '#{snapshot_id}' not found")
        end
        logger.info("snapshot '#{snapshot_id}' deleted")
      end
    end

    def configure_networks(_instance_id, _network_spec)
      raise Bosh::Clouds::NotSupported, 'configure_networks is no longer supported'
    end

    ##
    # Creates a new EC2 AMI using stemcell image. Light stemcells resolve an
    # existing AMI via the API; heavy stemcells are imported via the EBS direct
    # APIs (see #create_ami_for_stemcell).
    def create_stemcell(image_path, stemcell_properties)
      with_thread_name("create_stemcell(#{image_path}...)") do
        props = @props_factory.stemcell_props(stemcell_properties)

        if props.is_light?
          available_image = @ec2_resource.images(
            filters: [{
              name: 'image-id',
              values: props.ami_ids
            }],
            include_deprecated: true,
          ).first
          raise Bosh::Clouds::CloudError, "Stemcell does not contain an AMI in region #{@config.aws.region}" unless available_image

          if props.encrypted
            copy_image_result = @ec2_client.copy_image(
              source_region: @config.aws.region,
              source_image_id: props.region_ami,
              name: "Copied from SourceAMI #{props.region_ami}",
              encrypted: props.encrypted,
              kms_key_id: props.kms_key_arn
            )

            encrypted_image_id = copy_image_result.image_id
            encrypted_image = @ec2_resource.image(encrypted_image_id)
            ResourceWait.for_image(image: encrypted_image, state: 'available')

            return encrypted_image_id.to_s
          end

          "#{available_image.id} light"
        else
          create_ami_for_stemcell(image_path, props, props.tags)
        end
      end
    end

    def delete_stemcell(stemcell_id)
      with_thread_name("delete_stemcell(#{stemcell_id})") do
        stemcell = StemcellFinder.find_by_id(@ec2_resource, stemcell_id)
        stemcell.delete
      end
    end

    def calculate_vm_cloud_properties(vm_properties)
      required_keys = ['cpu', 'ram', 'ephemeral_disk_size']
      missing_keys = required_keys.reject { |key| vm_properties[key] }
      unless missing_keys.empty?
        missing_keys.map! { |k| "'#{k}'" }
        raise "Missing VM cloud properties: #{missing_keys.join(', ')}"
      end

      instance_type = @instance_type_mapper.map(vm_properties)
      {
        'instance_type' => instance_type,
        'ephemeral_disk' => {
          'size' => vm_properties['ephemeral_disk_size']
        }
      }
    end

    def info
      @cloud_core = CloudCore.new(@config, @logger, @volume_manager, @az_selector, API_VERSION)
      @cloud_core.info
    end

    private

    def update_agent_settings(instance_id)
      raise ArgumentError, 'block is not provided' unless block_given?

      settings = registry.read_settings(instance_id)
      yield settings
      registry.update_settings(instance_id, settings)
      logger.debug("updated registry settings: #{registry.read_settings(instance_id)}")
    end

    # Heavy-stemcell path, shared by CloudV1 and CloudV3 so the two API versions
    # cannot diverge. Callers pass the tags correct for their version (props.tags
    # for V1, the env argument for V3).
    def create_ami_for_stemcell(image_path, stemcell_cloud_props, tags = nil)
      creator = StemcellCreator.new(@ec2_resource, stemcell_cloud_props, @config.aws)

      logger.info('Creating stemcell via EBS direct APIs')
      creator.create(
        image_path,
        encrypted: !!stemcell_cloud_props.encrypted,
        kms_key_arn: stemcell_cloud_props.kms_key_arn,
        tags: tags || {},
      ).id
    end

    def get_volume_ids_for_vm(vm_instance)
      vm_instance.block_device_mappings.select(&:ebs)
                 .map { |block_device| block_device.ebs.volume_id }
    end
  end
end
