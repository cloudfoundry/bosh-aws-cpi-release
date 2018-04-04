require 'cloud/aws/stemcell_finder'
require 'uri'
require 'cloud_v2'

module Bosh::AwsCloud
  class CloudV2 < Bosh::AwsCloud::Cloud
    #include Bosh::CloudV2

    CPI_API_VERSION = 2
    METADATA_TIMEOUT = 5 # in seconds
    DEVICE_POLL_TIMEOUT = 60 # in seconds

    ##
    # Initialize BOSH AWS CPI. The contents of sub-hashes are defined in the {file:README.md}
    # @param [Integer] cpi_api_version API version to use for this CPI call
    # @param [Hash] options CPI options
    # @option options [Hash] aws AWS specific options
    # @option options [Hash] agent agent options
    # @option options [Hash] registry agent options
    def initialize(cpi_api_version, options)
      super(options)
      @cpi_api_version = cpi_api_version || CPI_API_VERSION
    end

    # Information about AWS CPI, currently supported stemcell formats
    # @return [Hash] AWS CPI properties
    def info
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
    # @param [Hash] network_spec network specification, if it contains
    #  security groups they must already exist
    # @param [optional, Array] disk_locality list of disks that
    #   might be attached to this instance in the future, can be
    #   used as a placement hint (i.e. instance will only be created
    #   if resource pool availability zone is the same as disk
    #   availability zone)
    # @param [optional, Hash] environment data to be merged into
    #   agent settings
    # @return [Hash] Contains VM ID, list of networks and disk_hints for attached disks
    def create_vm(agent_id, stemcell_id, vm_type, network_spec, disk_locality = [], environment = nil)
      vm_cid = super(agent_id, stemcell_id, vm_type, network_spec, disk_locality, environment)
      # vm_cid = aws_cloud.create_vm(agent_id, stemcell_id, vm_type, network_spec, disk_locality, environment)
      {
        'vm_cid' => vm_cid
      }
    end

    # Attaches a disk
    # @param [String] vm vm id that was once returned by {#create_vm}
    # @param [String] disk disk id that was once returned by {#create_disk}
    # @param [Hash] disk_hints list of attached disks {#create_disk}
    # @return [Hash] hint for location of attached disk
    def attach_disk(vm_id, disk_id, disk_hints={})
      # aws_cloud.attach_disk(vm_id, disk_id)
      super(vm_id, disk_id)
      #this will be replaced by metadata service calls
      # settings = aws_cloud.registry.read_settings(vm_id)
      settings = registry.read_settings(vm_id)
      {
        'device_name' => settings['disks']['persistent'][disk_id]
      }
    end
  end
end
