require 'common/common'
require 'time'

module Bosh::AwsCloud
  class AbruptlyTerminated < Bosh::Clouds::CloudError; end
  class InstanceManager
    include Helpers

    def initialize(ec2, registry, logger)
      @ec2 = ec2
      @registry = registry
      @logger = logger

      security_group_mapper = SecurityGroupMapper.new(@ec2)
      @param_mapper = InstanceParamMapper.new(security_group_mapper)
      @block_device_manager = BlockDeviceManager.new(@logger)
    end

    def create(stemcell_id, vm_cloud_props, networks_cloud_props, disk_locality, default_security_groups)
      ami = @ec2.image(stemcell_id)
      @block_device_manager.vm_type = vm_cloud_props
      @block_device_manager.virtualization_type = ami.virtualization_type
      @block_device_manager.root_device_name = ami.root_device_name
      @block_device_manager.ami_block_device_names = ami.block_device_mappings.map { |blk| blk.device_name }
      block_device_info = @block_device_manager.mappings
      block_device_agent_info = @block_device_manager.agent_info

      abruptly_terminated_retries = 2
      begin
        instance_params = build_instance_params(
          stemcell_id,
          vm_cloud_props,
          networks_cloud_props,
          block_device_info,
          disk_locality,
          default_security_groups
        )

        redacted_instance_params = Bosh::Cpi::Redactor.clone_and_redact(
          instance_params,
          'user_data',
          'defaults.access_key_id',
          'defaults.secret_access_key'
        )
        @logger.info("Creating new instance with: #{redacted_instance_params.inspect}")

        aws_instance = create_aws_instance(instance_params, vm_cloud_props)

        instance = Instance.new(aws_instance, @registry, @logger)

        babysit_instance_creation(instance, vm_cloud_props)
      rescue => e
        if e.is_a?(Bosh::AwsCloud::AbruptlyTerminated)
          @logger.warn("Failed to configure instance '#{instance.id}': #{e.inspect}")
          if (abruptly_terminated_retries -= 1) >= 0
            @logger.warn("Instance '#{instance.id}' was abruptly terminated, attempting to re-create': #{e.inspect}")
            retry
          end
        end
        raise
      end

      return instance, block_device_agent_info
    end

    # @param [String] instance_id EC2 instance id
    def find(instance_id)
      Instance.new(@ec2.instance(instance_id), @registry, @logger)
    end

    private

    def babysit_instance_creation(instance, vm_cloud_props)
      begin
        # We need to wait here for the instance to be running, as if we are going to
        # attach to a load balancer, the instance must be running.
        instance.wait_for_running
        instance.update_routing_tables(vm_cloud_props.advertised_routes)
        instance.source_dest_check = vm_cloud_props.source_dest_check
      rescue => e
        if e.is_a?(Bosh::AwsCloud::AbruptlyTerminated)
          raise
        else
          @logger.warn("Failed to configure instance '#{instance.id}': #{e.inspect}")
          begin
            instance.terminate
          rescue => e
            @logger.error("Failed to terminate mis-configured instance '#{instance.id}': #{e.inspect}")
          end
          raise
        end
      end
    end

    def build_instance_params(stemcell_id, vm_cloud_props, networks_cloud_props, block_device_mappings, disk_locality = [], default_security_groups = [])
      volume_zones = (disk_locality || []).map { |volume_id| @ec2.volume(volume_id).availability_zone }

      @param_mapper.manifest_params = {
        stemcell_id: stemcell_id,
        vm_type: vm_cloud_props,
        registry_endpoint: @registry.endpoint,
        networks_spec: networks_cloud_props,
        default_security_groups: default_security_groups,
        volume_zones: volume_zones,
        subnet_az_mapping: subnet_az_mapping(networks_cloud_props),
        block_device_mappings: block_device_mappings
      }
      @param_mapper.validate
      @param_mapper.instance_params
    end

    def create_aws_spot_instance(launch_specification, spot_bid_price)
      @logger.info('Launching spot instance...')
      spot_manager = Bosh::AwsCloud::SpotManager.new(@ec2)

      spot_manager.create(launch_specification, spot_bid_price)
    end

    def create_aws_instance(instance_params, vm_cloud_props)
      if vm_cloud_props.spot_bid_price
        begin
          return create_aws_spot_instance(
            instance_params,
            vm_cloud_props.spot_bid_price
          )
        rescue Bosh::Clouds::VMCreationFailed => e
          if vm_cloud_props.spot_ondemand_fallback
            @logger.info("Spot instance creation failed with this message: #{e.message}; will create ondemand instance because `spot_ondemand_fallback` is set.")
          else
            message = "Spot instance creation failed: #{e.inspect}"
            @logger.warn(message)
            raise e, message
          end
        end
      end

      instance_params[:min_count] = 1
      instance_params[:max_count] = 1

      # Retry the create instance operation a couple of times if we are told that the IP
      # address is in use - it can happen when the director recreates a VM and AWS
      # is too slow to update its state when we have released the IP address and want to
      # reallocate it again.
      errors = [Aws::EC2::Errors::InvalidIPAddressInUse]
      Bosh::Common.retryable(sleep: instance_create_wait_time, tries: 20, on: errors) do |tries, error|
        @logger.info('Launching on demand instance...')
        if error.class == Aws::EC2::Errors::InvalidIPAddressInUse
          @logger.warn("IP address was in use: #{error}")
        end
        resp = @ec2.client.run_instances(instance_params)
        @ec2.instance(get_created_instance_id(resp))
      end
    end

    def get_created_instance_id(resp)
      resp.instances.first.instance_id
    end

    def instance_create_wait_time
      30
    end

    def subnet_az_mapping(networks_cloud_props)
      subnet_ids = networks_cloud_props.filter('dynamic', 'manual').map do |net|
        net.subnet if net.cloud_properties?
      end
      filtered_subnets = @ec2.subnets(
        filters: [{
          name: 'subnet-id',
          values: subnet_ids
        }]
      )

      filtered_subnets.inject({}) do |mapping, subnet|
        mapping[subnet.id] = subnet.availability_zone
        mapping
      end
    end
  end
end
