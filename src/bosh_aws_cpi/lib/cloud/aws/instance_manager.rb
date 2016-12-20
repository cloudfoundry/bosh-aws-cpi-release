require "common/common"
require "time"

module Bosh::AwsCloud
  class InstanceManager
    include Helpers

    def initialize(ec2, registry, elb, param_mapper, block_device_manager, logger)
      @ec2 = ec2
      @registry = registry
      @elb = elb
      @param_mapper = param_mapper
      @block_device_manager = block_device_manager
      @logger = logger
    end

    def create(agent_id, stemcell_id, vm_type, networks_spec, disk_locality, environment, options)
      ami = @ec2.image(stemcell_id)
      @block_device_manager.vm_type = vm_type
      @block_device_manager.virtualization_type = ami.virtualization_type
      @block_device_manager.root_device_name = ami.root_device_name
      @block_device_manager.ami_block_device_names = ami.block_device_mappings.map { |blk| blk.device_name }
      block_device_info = @block_device_manager.mappings
      block_device_agent_info = @block_device_manager.agent_info

      instance_params = build_instance_params(stemcell_id, vm_type, networks_spec, block_device_info, disk_locality, options)

      @logger.info("Creating new instance with: #{instance_params.inspect}")

      aws_instance = create_aws_instance(instance_params, vm_type)

      instance = Instance.new(aws_instance, @registry, @elb, @logger)

      begin
        # We need to wait here for the instance to be running, as if we are going to
        # attach to a load balancer, the instance must be running.
        instance.wait_for_running
        instance.attach_to_load_balancers(vm_type['elbs'] || [])
        instance.update_routing_tables(vm_type['advertised_routes'] || [])
        if vm_type['source_dest_check'].to_s == 'false'
          instance.source_dest_check = false
        end
      rescue => e
        @logger.warn("Failed to configure instance '#{instance.id}': #{e.inspect}")
        begin
          instance.terminate
        rescue => e
          @logger.error("Failed to terminate mis-configured instance '#{instance.id}': #{e.inspect}")
        end
        raise
      end

      return instance, block_device_agent_info
    end

    # @param [String] instance_id EC2 instance id
    def find(instance_id)
      Instance.new(@ec2.instance(instance_id), @registry, @elb, @logger)
    end

    private

    def build_instance_params(stemcell_id, vm_type, networks_spec, block_device_mappings, disk_locality = [], options = {})
      volume_zones = (disk_locality || []).map { |volume_id| @ec2.volume(volume_id).availability_zone }

      @param_mapper.manifest_params = {
        stemcell_id: stemcell_id,
        vm_type: vm_type,
        registry_endpoint: @registry.endpoint,
        networks_spec: networks_spec,
        defaults: options['aws'],
        volume_zones: volume_zones,
        subnet_az_mapping: subnet_az_mapping(networks_spec),
        block_device_mappings: block_device_mappings,
      }
      @param_mapper.validate
      instance_params = @param_mapper.instance_params

      return instance_params
    end

    def create_aws_spot_instance(instance_params, spot_bid_price)
      @logger.info('Launching spot instance...')
      spot_manager = Bosh::AwsCloud::SpotManager.new(@ec2)

      spot_manager.create(instance_params, spot_bid_price)
    end

    def create_aws_instance(instance_params, vm_type)
      if vm_type['spot_bid_price']
        begin
          return create_aws_spot_instance instance_params, vm_type['spot_bid_price']
        rescue Bosh::Clouds::VMCreationFailed => e
          unless vm_type["spot_ondemand_fallback"]
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

    def subnet_az_mapping(networks_spec)
      subnet_networks = networks_spec.select { |net, spec| ["dynamic", "manual", nil].include?(spec["type"]) }
      subnet_ids = subnet_networks.values.map { |spec| spec["cloud_properties"]["subnet"] unless spec["cloud_properties"].nil? }
      filtered_subnets = @ec2.subnets({
        filters: [{
          name: 'subnet-id',
          values: subnet_ids
        }]
      })
      filtered_subnets.inject({}) do |mapping, subnet|
        mapping[subnet.id] = subnet.availability_zone
        mapping
      end
    end
  end
end
