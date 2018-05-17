require 'cloud/aws/stemcell_finder'
require 'uri'
require 'cloud_v2'

module Bosh::AwsCloud
  class CloudV2 < Bosh::AwsCloud::CloudV1
    METADATA_TIMEOUT = 5 # in seconds
    DEVICE_POLL_TIMEOUT = 60 # in seconds
    REGISTRY_REQUIRED = false

    ##
    # Initialize BOSH AWS CPI. The contents of sub-hashes are defined in the {file:README.md}
    # @param [Hash] options CPI options
    # @option options [Hash] aws AWS specific options
    # @option options [Hash] agent agent options
    # @option options [Hash] registry agent options
    def initialize(options)
      super(options)

      @config = Bosh::AwsCloud::Config.build(options.dup.freeze, REGISTRY_REQUIRED)
      @stemcell_api_version = @config.stemcell_api_version
      @logger = Bosh::Clouds::Config.logger
      request_id = options['aws']['request_id']
      if request_id
        @logger.set_request_id(request_id)
      end

      @registry = Bosh::Cpi::RegistryClient.new(
        @config.registry.endpoint,
        @config.registry.user,
        @config.registry.password
      )

      @cloud_core = CloudCore.new(@config, @logger, @volume_manager, @az_selector)
      @props_factory = Bosh::AwsCloud::PropsFactory.new(@config)
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
    # @return [Array] Contains VM ID, and Network info
    def create_vm(agent_id, stemcell_id, vm_type, network_spec, disk_locality = [], environment = nil)
      with_thread_name("create_vm(#{agent_id}, ...)") do
        network_props = @props_factory.network_props(network_spec)

        registry = {endpoint: @registry.endpoint}
        network_with_dns = network_props.dns_networks.first
        dns = {nameserver: network_with_dns.dns} unless network_with_dns.nil?
        registry_settings = AgentSettings.new(registry, network_props, dns)
        registry_settings.environment = environment
        registry_settings.agent_id = agent_id

        #TODO : should use networks from core create_vm in future
        instance_id, networks = @cloud_core.create_vm(agent_id, stemcell_id, vm_type, network_props, registry_settings, disk_locality, environment) do
        |instance_id, settings|
          @registry.update_settings(instance_id, settings.agent_settings) if @stemcell_api_version < 2
        end

        [instance_id, network_spec]
      end
    end

    # Attaches a disk
    # @param [String] vm_id vm id that was once returned by {#create_vm}
    # @param [String] disk_id disk id that was once returned by {#create_disk}
    # @param [Hash] disk_hints list of attached disks {#create_disk}
    # @return [String] hint for location of attached disk
    def attach_disk(vm_id, disk_id, disk_hints = {})
      # aws_cloud.attach_disk(vm_id, disk_id)
      super(vm_id, disk_id)
      #this will be replaced by metadata service calls
      settings = registry.read_settings(vm_id)
      settings['disks']['persistent'][disk_id]
    end

    ##
    # Delete EC2 instance ("terminate" in AWS language) and wait until
    # it reports as terminated
    # @param [String] instance_id EC2 instance id
    def delete_vm(instance_id)
      with_thread_name("delete_vm(#{instance_id})") do
        logger.info("Deleting instance '#{instance_id}'")
        @cloud_core.delete_vm(instance_id) do |instance_id|
          @registry.delete_settings(instance_id) if @stemcell_api_version < 2
        end
      end
    end
  end
end
