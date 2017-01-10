require 'cloud/aws/stemcell_finder'
require 'uri'

module Bosh::AwsCloud
  class Cloud < Bosh::Cloud
    include Helpers

    METADATA_TIMEOUT = 5 # in seconds
    DEVICE_POLL_TIMEOUT = 60 # in seconds

    attr_reader :ec2_resource
    attr_reader :registry
    attr_reader :options
    attr_accessor :logger

    ##
    # Initialize BOSH AWS CPI. The contents of sub-hashes are defined in the {file:README.md}
    # @param [Hash] options CPI options
    # @option options [Hash] aws AWS specific options
    # @option options [Hash] agent agent options
    # @option options [Hash] registry agent options
    def initialize(options)
      @options = options.dup.freeze
      validate_options
      validate_credentials_source

      @logger = Bosh::Clouds::Config.logger
      aws_logger = @logger

      @aws_params = {
        retry_limit: aws_properties['max_retries'],
        logger: aws_logger,
        log_level: :debug,
      }

      if aws_properties['region']
        @aws_params[:region] = aws_properties['region']
      end
      if aws_properties['ec2_endpoint']
        endpoint = aws_properties['ec2_endpoint']
        if URI(aws_properties['ec2_endpoint']).scheme.nil?
          endpoint = "https://#{endpoint}"
        end
        @aws_params[:endpoint] = endpoint
      end

      if ENV.has_key?('BOSH_CA_CERT_FILE')
        @aws_params[:ssl_ca_bundle] = ENV['BOSH_CA_CERT_FILE']
      end

      # credentials_source could be static (default) or env_or_profile
      # - if "static", credentials must be provided
      # - if "env_or_profile", credentials are read from instance metadata
      credentials_source = aws_properties['credentials_source'] || 'static'

      if credentials_source == 'static'
        @aws_params[:credentials] = Aws::Credentials.new(aws_properties['access_key_id'], aws_properties['secret_access_key'])
      else
        @aws_params[:credentials] = Aws::InstanceProfileCredentials.new({retries: 10})
      end

      # AWS Ruby SDK is threadsafe but Ruby autoload isn't,
      # so we need to trigger eager autoload while constructing CPI
      Aws.eager_autoload!

      # In SDK v2 the default is more request driven, while the old 'model way' lives in Resource.
      # Therefore in most cases Aws::EC2::Resource would replace the client.
      @ec2_client = Aws::EC2::Client.new(@aws_params)
      @ec2_resource = Aws::EC2::Resource.new(client: @ec2_client)

      cloud_error("Please make sure the CPI has proper network access to AWS.") unless aws_accessible?

      @az_selector = AvailabilityZoneSelector.new(@ec2_resource)

      initialize_registry

      elb_options = {
        region: @aws_params[:region],
        credentials: @aws_params[:credentials],
        logger: @logger,
      }

      elb_endpoint = aws_properties['elb_endpoint']
      if elb_endpoint
        if URI(aws_properties['elb_endpoint']).scheme.nil?
          elb_endpoint = "https://#{elb_endpoint}"
        end
        elb_options[:endpoint] = elb_endpoint
      end

      elb = Aws::ElasticLoadBalancing::Client.new(elb_options)

      security_group_mapper = SecurityGroupMapper.new(@ec2_resource)
      instance_param_mapper = InstanceParamMapper.new(security_group_mapper)
      block_device_manager = BlockDeviceManager.new(@logger)
      @instance_manager = InstanceManager.new(@ec2_resource, registry, elb, instance_param_mapper, block_device_manager, @logger)

      @instance_type_mapper = InstanceTypeMapper.new

      @metadata_lock = Mutex.new
    end

    ##
    # Reads current instance id from EC2 metadata. We are assuming
    # instance id cannot change while current process is running
    # and thus memoizing it.
    def current_vm_id
      @metadata_lock.synchronize do
        return @current_vm_id if @current_vm_id

        http_client = HTTPClient.new
        http_client.connect_timeout = METADATA_TIMEOUT
        # Using 169.254.169.254 is an EC2 convention for getting
        # instance metadata
        uri = "http://169.254.169.254/latest/meta-data/instance-id/"

        response = http_client.get(uri)
        unless response.status == 200
          cloud_error("Instance metadata endpoint returned " \
                      "HTTP #{response.status}")
        end

        @current_vm_id = response.body
      end

    rescue HTTPClient::TimeoutError
      cloud_error("Timed out reading instance metadata, " \
                  "please make sure CPI is running on EC2 instance")
    end

    ##
    # Create an EC2 instance and wait until it's in running state
    # @param [String] agent_id agent id associated with new VM
    # @param [String] stemcell_id AMI id of the stemcell used to
    #  create the new instance
    # @param [Hash] vm_type resource pool specification
    # @param [Hash] network_spec network specification, if it contains
    #  security groups they must already exist
    # @param [optional, Array] disk_locality list of disks that
    #   might be attached to this instance in the future, can be
    #   used as a placement hint (i.e. instance will only be created
    #   if resource pool availability zone is the same as disk
    #   availability zone)
    # @param [optional, Hash] environment data to be merged into
    #   agent settings
    # @return [String] EC2 instance id of the new virtual machine
    def create_vm(agent_id, stemcell_id, vm_type, network_spec, disk_locality = nil, environment = nil)
      with_thread_name("create_vm(#{agent_id}, ...)") do
        # do this early to fail fast
        stemcell = StemcellFinder.find_by_id(@ec2_resource, stemcell_id)

        begin
          instance, block_device_agent_info = @instance_manager.create(
            agent_id,
            stemcell.image_id,
            vm_type,
            network_spec,
            (disk_locality || []),
            environment,
            options,
          )

          logger.info("Creating new instance '#{instance.id}'")

          NetworkConfigurator.new(network_spec).configure(@ec2_resource, instance)

          registry_settings = initial_agent_settings(
            agent_id,
            network_spec,
            environment,
            stemcell.root_device_name,
            block_device_agent_info
          )
          registry.update_settings(instance.id, registry_settings)

          instance.id
        rescue => e # is this rescuing too much?
          logger.error(%Q[Failed to create instance: #{e.message}\n#{e.backtrace.join("\n")}])
          instance.terminate(fast_path_delete?) if instance
          raise e
        end
      end
    end

    ##
    # Delete EC2 instance ("terminate" in AWS language) and wait until
    # it reports as terminated
    # @param [String] instance_id EC2 instance id
    def delete_vm(instance_id)
      with_thread_name("delete_vm(#{instance_id})") do
        logger.info("Deleting instance '#{instance_id}'")
        @instance_manager.find(instance_id).terminate(fast_path_delete?)
      end
    end

    ##
    # Reboot EC2 instance
    # @param [String] instance_id EC2 instance id
    def reboot_vm(instance_id)
      with_thread_name("reboot_vm(#{instance_id})") do
        @instance_manager.find(instance_id).reboot
      end
    end

    ##
    # Has EC2 instance
    # @param [String] instance_id EC2 instance id
    def has_vm?(instance_id)
      with_thread_name("has_vm?(#{instance_id})") do
        @instance_manager.find(instance_id).exists?
      end
    end

    ##
    # Creates a new EBS volume
    # @param [Integer] size disk size in MiB
    # @param [optional, String] instance_id EC2 instance id
    #        of the VM that this disk will be attached to
    # @return [String] created EBS volume id
    def create_disk(size, cloud_properties, instance_id = nil)
      raise ArgumentError, 'disk size needs to be an integer' unless size.kind_of?(Integer)
      with_thread_name("create_disk(#{size}, #{instance_id})") do
        volume_properties = VolumeProperties.new(
          size: size,
          type: cloud_properties['type'],
          iops: cloud_properties['iops'],
          az: @az_selector.select_availability_zone(instance_id),
          encrypted: cloud_properties['encrypted'],
          kms_key_arn: cloud_properties['kms_key_arn']
        )

        volume_resp = @ec2_client.create_volume(volume_properties.persistent_disk_config)
        volume = Aws::EC2::Volume.new(
          id: volume_resp.volume_id,
          client: @ec2_client,
        )

        logger.info("Creating volume '#{volume.id}'")
        ResourceWait.for_volume(volume: volume, state: 'available')

        volume.id
      end
    end

    ##
    # Check whether an EBS volume exists or not
    #
    # @param [String] disk_id EBS volume UUID
    # @return [bool] whether the specific disk is there or not
    def has_disk?(disk_id)
      with_thread_name("has_disk?(#{disk_id})") do
        @logger.info("Check the presence of disk with id `#{disk_id}'...")
        volume = @ec2_resource.volume(disk_id)
        begin
          volume.state
        rescue Aws::EC2::Errors::InvalidVolumeNotFound
          return false
        end
        true
      end
    end

    ##
    # Delete EBS volume
    # @param [String] disk_id EBS volume id
    # @raise [Bosh::Clouds::CloudError] if disk is not in available state
    def delete_disk(disk_id)
      with_thread_name("delete_disk(#{disk_id})") do
        volume = @ec2_resource.volume(disk_id)

        logger.info("Deleting volume `#{volume.id}'")

        # Retry 1, 6, 11, 15, 15, 15.. seconds. The total time is ~10 min.
        # VolumeInUse can be returned by AWS if disk was attached to VM
        # that was recently removed.
        tries = ResourceWait::DEFAULT_WAIT_ATTEMPTS
        sleep_cb = ResourceWait.sleep_callback(
          "Waiting for volume `#{volume.id}' to be deleted",
          {interval: 5, total: tries}
        )
        ensure_cb = Proc.new do |retries|
          cloud_error("Timed out waiting to delete volume `#{volume.id}'") if retries == tries
        end
        error = Aws::EC2::Errors::VolumeInUse

        Bosh::Common.retryable(tries: tries, sleep: sleep_cb, on: error, ensure: ensure_cb) do
          begin
            volume.delete
          rescue Aws::EC2::Errors::InvalidVolumeNotFound => e
            logger.warn("Failed to delete disk '#{disk_id}' because it was not found: #{e.inspect}")
            raise Bosh::Clouds::DiskNotFound.new(false), "Disk '#{disk_id}' not found"
          end
          true # return true to only retry on Exceptions
        end

        if fast_path_delete?
          begin
            TagManager.tag(volume, "Name", "to be deleted")
            logger.info("Volume `#{disk_id}' has been marked for deletion")
          rescue Aws::EC2::Errors::InvalidVolumeNotFound
            # Once in a blue moon AWS if actually fast enough that the volume is already gone
            # when we get here, and if it is, our work here is done!
          end
          return
        end

        ResourceWait.for_volume(volume: volume, state: 'deleted')

        logger.info("Volume `#{disk_id}' has been deleted")
      end
    end

    # Attach an EBS volume to an EC2 instance
    # @param [String] instance_id EC2 instance id of the virtual machine to attach the disk to
    # @param [String] disk_id EBS volume id of the disk to attach
    def attach_disk(instance_id, disk_id)
      with_thread_name("attach_disk(#{instance_id}, #{disk_id})") do
        instance = @ec2_resource.instance(instance_id)
        volume = @ec2_resource.volume(disk_id)

        device_name = attach_ebs_volume(instance, volume)

        update_agent_settings(instance) do |settings|
          settings["disks"] ||= {}
          settings["disks"]["persistent"] ||= {}
          settings["disks"]["persistent"][disk_id] = device_name
        end
        logger.info("Attached `#{disk_id}' to `#{instance_id}'")
      end

      # log registry settings for debugging
      logger.debug("updated registry settings: #{registry.read_settings(instance_id)}")
    end

    # Detach an EBS volume from an EC2 instance
    # @param [String] instance_id EC2 instance id of the virtual machine to detach the disk from
    # @param [String] disk_id EBS volume id of the disk to detach
    def detach_disk(instance_id, disk_id)
      with_thread_name("detach_disk(#{instance_id}, #{disk_id})") do
        instance = @ec2_resource.instance(instance_id)
        volume = @ec2_resource.volume(disk_id)

        if has_disk?(disk_id)
          detach_ebs_volume(instance, volume)
        else
          @logger.info("Disk `#{disk_id}' not found while trying to detach it from vm `#{instance_id}'...")
        end

        update_agent_settings(instance) do |settings|
          settings["disks"] ||= {}
          settings["disks"]["persistent"] ||= {}
          settings["disks"]["persistent"].delete(disk_id)
        end

        logger.info("Detached `#{disk_id}' from `#{instance_id}'")
      end
    end

    def get_disks(vm_id)
      disks = []
      @ec2_resource.instance(vm_id).block_device_mappings.each do |block_device|
        if block_device.ebs
          disks << block_device.ebs.volume_id
        end
      end
      disks
    end

    # Take snapshot of disk
    # @param [String] disk_id disk id of the disk to take the snapshot of
    # @return [String] snapshot id
    def snapshot_disk(disk_id, metadata)
      metadata = Hash[metadata.map { |key, value| [key.to_s, value] }]

      with_thread_name("snapshot_disk(#{disk_id})") do
        volume = @ec2_resource.volume(disk_id)
        devices = []
        volume.attachments.each { |attachment| devices << attachment.device }

        name = ['deployment', 'job', 'index'].collect { |key| metadata[key] }
        name << devices.first.split('/').last unless devices.empty?

        snapshot = volume.create_snapshot(name.join('/'))
        logger.info("snapshot '#{snapshot.id}' of volume '#{disk_id}' created")

        ['agent_id', 'instance_id', 'director_name', 'director_uuid'].each do |key|
          TagManager.tag(snapshot, key, metadata[key])
        end
        TagManager.tag(snapshot, 'device', devices.first) unless devices.empty?
        TagManager.tag(snapshot, 'Name', name.join('/'))

        ResourceWait.for_snapshot(snapshot: snapshot, state: 'completed')
        snapshot.id
      end
    end

    # Delete a disk snapshot
    # @param [String] snapshot_id snapshot id to delete
    def delete_snapshot(snapshot_id)
      with_thread_name("delete_snapshot(#{snapshot_id})") do
        snapshot = @ec2_resource.snapshot(snapshot_id)
        snapshot.delete
        logger.info("snapshot '#{snapshot_id}' deleted")
      end
    end

    # Configure network for an EC2 instance. No longer supported.
    # @param [String] instance_id EC2 instance id
    # @param [Hash] network_spec network properties
    # @raise [Bosh::Clouds:NotSupported] configure_networks is no longer supported
    def configure_networks(instance_id, network_spec)
      raise Bosh::Clouds::NotSupported, "configure_networks is no longer supported"
    end

    ##
    # Creates a new EC2 AMI using stemcell image.
    # This method can only be run on an EC2 instance, as image creation
    # involves creating and mounting new EBS volume as local block device.
    # @param [String] image_path local filesystem path to a stemcell image
    # @param [Hash] cloud_properties AWS-specific stemcell properties
    # @option cloud_properties [String] kernel_id
    #   AKI, auto-selected based on the architecture and root device, unless specified
    # @option cloud_properties [String] root_device_name
    #   block device path (e.g. /dev/sda1), provided by the stemcell manifest, unless specified
    # @option cloud_properties [String] architecture
    #   instruction set architecture (e.g. x86_64), provided by the stemcell manifest,
    #   unless specified
    # @option cloud_properties [String] disk (2048)
    #   root disk size
    # @return [String] EC2 AMI name of the stemcell
    def create_stemcell(image_path, stemcell_properties)
      with_thread_name("create_stemcell(#{image_path}...)") do
        stemcell_properties.merge!(aws_properties['stemcell'] || {})

        if stemcell_properties.has_key?('ami')
          all_ami_ids = stemcell_properties['ami'].values

          # select the correct image for the configured ec2 client
          available_image = @ec2_resource.images(
            {
              filters: [{
                name: 'image-id',
                values: all_ami_ids
              }]
            }
          ).first
          raise Bosh::Clouds::CloudError, "Stemcell does not contain an AMI at endpoint (#{@ec2_resource.client.endpoint})" unless available_image

          "#{available_image.id} light"
        else
          create_ami_for_stemcell(image_path, stemcell_properties)
        end
      end
    end

    # Delete a stemcell and the accompanying snapshots
    # @param [String] stemcell_id EC2 AMI name of the stemcell to be deleted
    def delete_stemcell(stemcell_id)
      with_thread_name("delete_stemcell(#{stemcell_id})") do
        stemcell = StemcellFinder.find_by_id(@ec2_resource, stemcell_id)
        stemcell.delete
      end
    end

    # Add tags to an instance. In addition to the supplied tags,
    # it adds a 'Name' tag as it is shown in the AWS console.
    # @param [String] vm vm id that was once returned by {#create_vm}
    # @param [Hash] metadata metadata key/value pairs
    # @return [void]
    def set_vm_metadata(vm, metadata)
      metadata = Hash[metadata.map { |key, value| [key.to_s, value] }]

      instance = @ec2_resource.instance(vm)

      # TODO: bulk update, single HTTP call (tracker id: #136591893)
      metadata.each_pair do |key, value|
        TagManager.tag(instance, key, value) unless key == 'name'
      end

      name = metadata['name']
      if name
        TagManager.tag(instance, "Name", name)
        return
      end

      job = metadata['job']
      index = metadata['index']

      if job && index
        name = "#{job}/#{index}"
      elsif metadata['compiling']
        name = "compiling/#{metadata['compiling']}"
      end
      TagManager.tag(instance, "Name", name) if name
    rescue Aws::EC2::Errors::TagLimitExceeded => e
      logger.error("could not tag #{instance.id}: #{e.message}")
    end

    # Map a set of cloud agnostic VM properties (cpu, ram, ephemeral_disk_size) to
    # a set of AWS specific cloud_properties
    # @param [Hash] vm_properties requested cpu, ram, and ephemeral_disk_size
    # @return [Hash] AWS specific cloud_properties describing instance (e.g. instance_type)
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
          'size' => vm_properties['ephemeral_disk_size'],
        }
      }
    end

    def find_device_path_by_name(sd_name)
      xvd_name = sd_name.gsub(/^\/dev\/sd/, "/dev/xvd")

      DEVICE_POLL_TIMEOUT.times do
        if File.blockdev?(sd_name)
          return sd_name
        elsif File.blockdev?(xvd_name)
          return xvd_name
        end
        sleep(1)
      end

      cloud_error("Cannot find EBS volume on current instance")
    end

    private

    attr_reader :az_selector

    def agent_properties
      @agent_properties ||= options.fetch('agent', {})
    end

    def aws_properties
      @aws_properties ||= options.fetch('aws')
    end

    def aws_region
      @aws_region ||= aws_properties.fetch('region', nil)
    end

    def fast_path_delete?
      aws_properties.fetch('fast_path_delete', false)
    end

    def initialize_registry
      registry_properties = options.fetch('registry')
      registry_endpoint = registry_properties.fetch('endpoint')
      registry_user = registry_properties.fetch('user')
      registry_password = registry_properties.fetch('password')

      # Registry updates are not really atomic in relation to
      # EC2 API calls, so they might get out of sync. Cloudcheck
      # is supposed to fix that.
      @registry = Bosh::Cpi::RegistryClient.new(registry_endpoint,
        registry_user,
        registry_password)
    end

    def update_agent_settings(instance)
      unless block_given?
        raise ArgumentError, "block is not provided"
      end

      settings = registry.read_settings(instance.id)
      yield settings
      registry.update_settings(instance.id, settings)
    end

    def create_ami_for_stemcell(image_path, stemcell_properties)
      creator = StemcellCreator.new(@ec2_resource, stemcell_properties)

      begin
        instance = nil
        volume = nil

        instance = @ec2_resource.instance(current_vm_id)
        unless instance.exists?
          cloud_error(
            "Could not locate the current VM with id '#{current_vm_id}'." +
            "Ensure that the current VM is located in the same region as configured in the manifest."
          )
        end

        disk_size = stemcell_properties["disk"] || 2048
        volume_id = create_disk(disk_size, {}, current_vm_id)
        volume = @ec2_resource.volume(volume_id)

        sd_name = attach_ebs_volume(instance, volume)
        device_path = find_device_path_by_name(sd_name)

        logger.info("Creating stemcell with: '#{volume.id}' and '#{stemcell_properties.inspect}'")
        creator.create(volume, device_path, image_path).id
      rescue => e
        logger.error(e)
        raise e
      ensure
        if instance && volume
          detach_ebs_volume(instance.reload, volume, true)
          delete_disk(volume.id)
        end
      end
    end

    def attach_ebs_volume(instance, volume)
      device_name = select_device_name(instance)
      cloud_error('Instance has too many disks attached') unless device_name

      # Work around AWS eventual (in)consistency:
      # even tough we don't call attach_disk until the disk is ready,
      # AWS might still lie and say that the disk isn't ready yet, so
      # we try again just to be really sure it is telling the truth
      attachment_resp = nil

      logger.debug("Attaching '#{volume.id}' to '#{instance.id}' as '#{device_name}'")

      # Retry every 1 sec for 15 sec, then every 15 sec for ~10 min
      # VolumeInUse can be returned by AWS if disk was attached to VM
      # that was recently removed.
      tries = ResourceWait::DEFAULT_WAIT_ATTEMPTS
      sleep_cb = ResourceWait.sleep_callback(
        "Attaching volume `#{volume.id}' to #{instance.id}",
        {interval: 0, tries_before_max: 15, total: tries}
      )

      Bosh::Common.retryable(
        on: [Aws::EC2::Errors::IncorrectState, Aws::EC2::Errors::VolumeInUse],
        sleep: sleep_cb,
        tries: tries
      ) do |retries, error|
        # Continue to retry after 15 attempts only for VolumeInUse
        if retries > 15 && error.instance_of?(Aws::EC2::Errors::IncorrectState)
          cloud_error("Failed to attach disk: #{error.message}")
        end

        attachment_resp = volume.attach_to_instance({
          instance_id: instance.id,
          device: device_name,
        })
      end

      attachment = SdkHelpers::VolumeAttachment.new(attachment_resp, @ec2_resource)
      ResourceWait.for_attachment(attachment: attachment, state: 'attached')

      device_name = attachment.device
      logger.info("Attached '#{volume.id}' to '#{instance.id}' as '#{device_name}'")

      device_name
    end

    def select_device_name(instance)
      device_names = instance.block_device_mappings.map { |dm| dm.device_name }

      ('f'..'p').each do |char| # f..p is what console suggests
        device_name = "/dev/sd#{char}"
        return device_name unless device_names.include?(device_name)
        logger.warn("'#{device_name}' on '#{instance.id}' is taken")
      end

      nil
    end

    def detach_ebs_volume(instance, volume, force=false)
      device_mapping = instance.block_device_mappings.select { |dm| dm.ebs.volume_id == volume.id }.first
      if device_mapping.nil?
        raise Bosh::Clouds::DiskNotAttached.new(true),
          "Disk `#{volume.id}' is not attached to instance `#{instance.id}'"
      end

      attachment_resp = volume.detach_from_instance({
        instance_id: instance.id,
        device: device_mapping.device_name,
        force: force,
      })
      logger.info("Detaching `#{volume.id}' from `#{instance.id}'")

      attachment = SdkHelpers::VolumeAttachment.new(attachment_resp, @ec2_resource)
      ResourceWait.for_attachment(attachment: attachment, state: 'detached')
    end

    ##
    # Checks if options passed to CPI are valid and can actually
    # be used to create all required data structures etc.
    #
    def validate_options
      required_keys = {
        "aws" => ["default_key_name", "max_retries"],
        "registry" => ["endpoint", "user", "password"],
      }

      missing_keys = []

      required_keys.each_pair do |key, values|
        values.each do |value|
          if (!options.has_key?(key) || !options[key].has_key?(value))
            missing_keys << "#{key}:#{value}"
          end
        end
      end

      raise ArgumentError, "missing configuration parameters > #{missing_keys.join(', ')}" unless missing_keys.empty?

      if !options['aws'].has_key?('region') && ! (options['aws'].has_key?('ec2_endpoint') && options['aws'].has_key?('elb_endpoint'))
        raise ArgumentError, "missing configuration parameters > aws:region, or aws:ec2_endpoint and aws:elb_endpoint"
      end
    end

    ##
    # Checks AWS credentials settings to see if the CPI
    # will be able to authenticate to AWS.
    #
    def validate_credentials_source
      credentials_source = options['aws']['credentials_source'] || 'static'

      if credentials_source != 'env_or_profile' && credentials_source != 'static'
        raise ArgumentError, "Unknown credentials_source #{credentials_source}"
      end

      if credentials_source == 'static'
        if options['aws']['access_key_id'].nil? || options['aws']['secret_access_key'].nil?
          raise ArgumentError, "Must use access_key_id and secret_access_key with static credentials_source"
        end
      end

      if credentials_source == 'env_or_profile'
        if !options['aws']['access_key_id'].nil? || !options['aws']['secret_access_key'].nil?
          raise ArgumentError, "Can't use access_key_id and secret_access_key with env_or_profile credentials_source"
        end
      end
    end

    # Generates initial agent settings. These settings will be read by agent
    # from AWS registry (also a BOSH component) on a target instance. Disk
    # conventions for amazon are:
    # system disk: /dev/sda
    # ephemeral disk: /dev/sdb
    # EBS volumes can be configured to map to other device names later (sdf
    # through sdp, also some kernels will remap sd* to xvd*).
    #
    # @param [String] agent_id Agent id (will be picked up by agent to
    #   assume its identity
    # @param [Hash] network_spec Agent network spec
    # @param [Hash] environment
    # @param [String] root_device_name root device, e.g. /dev/sda1
    # @param [Hash] block_device_agent_info disk attachment information to merge into the disks section.
    #   keys are device type ("ephemeral", "raw_ephemeral") and values are array of strings representing the
    #   path to the block device. It is expected that "ephemeral" has exactly one value.
    # @return [Hash]
    def initial_agent_settings(agent_id, network_spec, environment, root_device_name, block_device_agent_info)
      settings = {
        "vm" => {
          "name" => "vm-#{SecureRandom.uuid}"
        },
        "agent_id" => agent_id,
        "networks" => agent_network_spec(network_spec),
        "disks" => {
          "system" => root_device_name,
          "persistent" => {}
        }
      }

      settings["disks"].merge!(block_device_agent_info)
      settings["disks"]["ephemeral"] = settings["disks"]["ephemeral"][0]["path"]

      settings["env"] = environment if environment
      settings.merge(agent_properties)
    end

    def agent_network_spec(network_spec)
      spec = network_spec.map do |name, settings|
        settings["use_dhcp"] = true
        [name, settings]
      end
      Hash[spec]
    end

    def strip_protocol(url)
      url.sub(/^https?\:\/\//, '')
    end

    def aws_accessible?
      # make an arbitrary HTTP request to ensure we can connect and creds are valid
      @ec2_resource.subnets.first
      true
    rescue Net::OpenTimeout
      false
    end
  end
end
