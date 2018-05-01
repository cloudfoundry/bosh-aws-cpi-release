require 'cloud/aws/stemcell_finder'
require 'uri'

module Bosh::AwsCloud
  class CloudCore
    include Helpers

    CPI_API_VERSION = 2
    METADATA_TIMEOUT = 5 # in seconds
    DEVICE_POLL_TIMEOUT = 60 # in seconds

    attr_reader :ec2_resource
    attr_reader :logger

    ##
    # Initialize BOSH AWS CPI. The contents of sub-hashes are defined in the {file:README.md}
    # @param [Bosh::AwsCloud::Config] config CPI Config options
    # @param [Bosh::Cpi::Logger] logger AWS specific options
    def initialize(config, logger, volume_manager, az_selector)
      @config = config
      @cpi_api_version = @config.api_version
      @logger = logger

      @aws_provider = Bosh::AwsCloud::AwsProvider.new(@config.aws, @logger)
      @ec2_client = @aws_provider.ec2_client
      @ec2_resource = @aws_provider.ec2_resource

      cloud_error('Please make sure the CPI has proper network access to AWS.') unless @aws_provider.aws_accessible?

      @az_selector = az_selector
      @volume_manager = volume_manager

      @instance_manager = InstanceManager.new(@ec2_resource, @logger)
      @instance_type_mapper = InstanceTypeMapper.new

      @props_factory = Bosh::AwsCloud::PropsFactory.new(@config)
    end

    # Information about AWS CPI, currently supported stemcell formats
    # @return [Hash] AWS CPI properties
    def info
      # TODO should this logger statement be removed?
      @logger.info("Sending info:V2'")
      {
        'stemcell_formats' => %w(aws-raw aws-light),
        'api_version' => CPI_API_VERSION
      }
    end

    ##
    # Create an EC2 instance and wait until it's in running state
    # @param [String] agent_id agent id associated with new VM
    # @param [String] stemcell_id AMI id of the stemcell used to
    #  create the new instance
    # @param [Hash] vm_type resource pool specification
    # @param [Bosh::AwsCloud::NetworkCloudProps] network_props network specification, if it contains
    #  security groups they must already exist
    # @param [optional, Array] disk_locality list of disks that
    #   might be attached to this instance in the future, can be
    #   used as a placement hint (i.e. instance will only be created
    #   if resource pool availability zone is the same as disk
    #   availability zone)
    # @param [optional, Hash] environment data to be merged into
    #   agent settings
    # @return [String] EC2 instance id of the new virtual machine
    def create_vm(agent_id, stemcell_id, vm_type, network_props, settings, disk_locality = [], environment = nil)
      vm_props = @props_factory.vm_props(vm_type)

      # do this early to fail fast
      target_groups = vm_props.lb_target_groups
      unless target_groups.empty?
        @aws_provider.alb_accessible?
      end

      requested_elbs = vm_props.elbs
      unless requested_elbs.empty?
        @aws_provider.elb_accessible?
      end

      begin
        stemcell = StemcellFinder.find_by_id(@ec2_resource, stemcell_id)

        ephemeral_disk_base_snapshot = temporary_snapshot(agent_id, vm_props)
        block_device_mappings, agent_info = Bosh::AwsCloud::BlockDeviceManager.new(
          @logger,
          stemcell,
          vm_props,
          ephemeral_disk_base_snapshot
        ).mappings_and_info

        settings.agent_disk_info = agent_info
        settings.root_device_name = stemcell.root_device_name
        settings.agent_config = @config.agent

        instance = @instance_manager.create(
          stemcell.image_id,
          vm_props,
          network_props,
          (disk_locality || []),
          @config.aws.default_security_groups,
          block_device_mappings,
          settings.encode(@cpi_api_version)
        )

        target_groups.each do |target_group_name|
          target_group = LBTargetGroup.new(client: @aws_provider.alb_client, group_name: target_group_name)
          target_group.register(instance.id)
        end

        requested_elbs.each do |requested_elb_name|
          requested_elb = ClassicLB.new(client: @aws_provider.elb_client, elb_name: requested_elb_name)
          requested_elb.register(instance.id)
        end

        logger.info("Creating new instance '#{instance.id}'")

        NetworkConfigurator.new(network_props).configure(@ec2_resource, instance)

        yield(instance.id, settings) if block_given?

        return instance.id, agent_info
      rescue => e # is this rescuing too much?
        logger.error(%Q[Failed to create instance: #{e.message}\n#{e.backtrace.join("\n")}])
        instance.terminate(@config.aws.fast_path_delete?) if instance
        raise e
      ensure
        ephemeral_disk_base_snapshot.delete if ephemeral_disk_base_snapshot
      end
    end

    def delete_vm(instance_id)
      @instance_manager.find(instance_id).terminate(@config.aws.fast_path_delete?)

      yield instance_id if block_given?
    end

    private
    def temporary_snapshot(agent_id, vm_cloud_props)
      if vm_cloud_props.custom_encryption?
        custom_kms_key_disk_config = VolumeProperties.new(
          size: 1024,
          type: vm_cloud_props.ephemeral_disk.type,
          iops: vm_cloud_props.ephemeral_disk.iops,
          encrypted: vm_cloud_props.ephemeral_disk.encrypted,
          kms_key_arn: vm_cloud_props.ephemeral_disk.kms_key_arn,
          az: vm_cloud_props.availability_zone,
          tags: [{key: "ephemeral_disk_agent_id", value: "temp-vol-bosh-agent-#{agent_id}"}]
        ).persistent_disk_config

        volume = @volume_manager.create_ebs_volume(custom_kms_key_disk_config)
        begin
          snapshot = volume.create_snapshot
          snapshot.create_tags(tags: [{key: "ephemeral_disk_agent_id", value: "temp-snapshot-bosh-agent-#{agent_id}"}])
          ResourceWait.for_snapshot(snapshot: snapshot, state: 'completed')
        ensure
          @volume_manager.delete_ebs_volume(volume)
        end
        snapshot
      else
        nil
      end
    end

  end
end
