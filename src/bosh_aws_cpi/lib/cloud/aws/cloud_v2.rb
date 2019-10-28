require 'cloud/aws/stemcell_finder'
require 'uri'
require 'cloud_v2'

module Bosh::AwsCloud
  class CloudV2 < Bosh::AwsCloud::CloudV1
    METADATA_TIMEOUT = 5 # in seconds
    DEVICE_POLL_TIMEOUT = 60 # in seconds

    # Current CPI API version supported by this CPI
    API_VERSION = 2

    # Stemcell API version that first supports optional-registry operation
    STEMCELL_NO_REGISTRY = 2

    # Stemcell API version that first supports signed urls. No CPI changes required.
    STEMCELL_SUPPORTS_SIGNED_URLS = 3

    ##
    # Initialize BOSH AWS CPI. The contents of sub-hashes are defined in the {file:README.md}
    # @param [Hash] options CPI options
    # @option options [Hash] aws AWS specific options
    # @option options [Hash] agent agent options
    # @option options [Hash] registry agent options
    def initialize(options)
      super(options)

      @stemcell_api_version = @config.stemcell_api_version
      @cloud_core = CloudCore.new(@config, @logger, @volume_manager, @az_selector, @stemcell_api_version)
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
      raise Bosh::Clouds::CloudError, "Cannot create VM without registry with CPI v2 and stemcell api version #{@stemcell_api_version}. Registry not configured." if !@config.registry_configured? && @stemcell_api_version < 2

      with_thread_name("create_vm(#{agent_id}, ...):v2") do
        network_props = @props_factory.network_props(network_spec)

        registry, dns = nil
        registry = {endpoint: @config.registry.endpoint} if @config.registry_configured?

        network_with_dns = network_props.dns_networks.first
        dns = {nameserver: network_with_dns.dns} unless network_with_dns.nil?
        agent_settings = AgentSettings.new(registry, network_props, dns)
        agent_settings.environment = environment
        agent_settings.agent_id = agent_id

        #TODO : should use networks from core create_vm in future
        instance_id, networks = @cloud_core.create_vm(agent_id, stemcell_id, vm_type, network_props, agent_settings, disk_locality, environment) do
        |instance_id, settings|
          @registry.update_settings(instance_id, settings.agent_settings) if @stemcell_api_version < 2
        end

        [instance_id, network_spec]
      end
    end

    # Attaches a disk
    # @param [String] vm_id vm id that was once returned by {#create_vm}
    # @param [String] disk_id disk id that was once returned by {#create_disk}
    # @return [String/Hash] hint for location of attached disk
    def attach_disk(vm_id, disk_id)
      with_thread_name("attach_disk(#{vm_id}, #{disk_id}):v2") do
        device_path = nil
        @cloud_core.attach_disk(vm_id, disk_id) do |instance, device_name|
          device_path = BlockDeviceManager.device_path(device_name, instance.instance_type, disk_id)
          if @stemcell_api_version < 2
            update_agent_settings(vm_id) do |settings|
              settings['disks'] ||= {}
              settings['disks']['persistent'] ||= {}
              settings['disks']['persistent'][disk_id] = device_path
            end
          end
        end
        device_path
      end
    end

    # Detach an EBS volume from an EC2 instance
    # @param [String] instance_id EC2 instance id of the virtual machine to detach the disk from
    # @param [String] disk_id EBS volume id of the disk to detach
    def detach_disk(instance_id, disk_id)
      with_thread_name("detach_disk(#{instance_id}, #{disk_id}):v2") do
        @cloud_core.detach_disk(instance_id, disk_id) do |disk_id|
          if @stemcell_api_version < 2
            update_agent_settings(instance_id) do |settings|
              settings['disks'] ||= {}
              settings['disks']['persistent'] ||= {}
              settings['disks']['persistent'].delete(disk_id)
            end
          end
        end
      end
    end

    ##
    # Delete EC2 instance ("terminate" in AWS language) and wait until
    # it reports as terminated
    # @param [String] instance_id EC2 instance id
    def delete_vm(instance_id)
      with_thread_name("delete_vm(#{instance_id}):v2") do
        logger.info("Deleting instance '#{instance_id}'")
        @cloud_core.delete_vm(instance_id) do |instance_id|
          @registry.delete_settings(instance_id) if @stemcell_api_version < 2
        end
      end
    end
  end
end
