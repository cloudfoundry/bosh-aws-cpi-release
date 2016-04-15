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

    def create(agent_id, stemcell_id, resource_pool, networks_spec, disk_locality, environment, options)
      @block_device_manager.resource_pool = resource_pool
      @block_device_manager.virtualization_type = @ec2.images[stemcell_id].virtualization_type
      block_device_info = @block_device_manager.mappings
      block_device_agent_info = @block_device_manager.agent_info

      instance_params = build_instance_params(stemcell_id, resource_pool, networks_spec, block_device_info, disk_locality, options)

      @logger.info("Creating new instance with: #{instance_params.inspect}")

      aws_instance = create_aws_instance(instance_params, resource_pool)

      instance = Instance.new(aws_instance, @registry, @elb, @logger)

      begin
        # We need to wait here for the instance to be running, as if we are going to
        # attach to a load balancer, the instance must be running.
        instance.wait_for_running
        instance.attach_to_load_balancers(resource_pool['elbs'] || [])
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
      Instance.new(@ec2.instances[instance_id], @registry, @elb, @logger)
    end

    private

    def build_instance_params(stemcell_id, resource_pool, networks_spec, block_device_mappings, disk_locality = [], options = {})
      volume_zones = (disk_locality || []).map { |volume_id| @ec2.volumes[volume_id].availability_zone.to_s }

      @param_mapper.manifest_params = {
        stemcell_id: stemcell_id,
        resource_pool: resource_pool,
        registry_endpoint: @registry.endpoint,
        networks_spec: networks_spec,
        defaults: options['aws'],
        volume_zones: volume_zones,
        subnet_az_mapping: subnet_az_mapping(networks_spec),
        block_device_mappings: block_device_mappings,
        sg_name_mapper: sg_name_mapper
      }
      @param_mapper.validate
      instance_params = @param_mapper.instance_params

      return instance_params
    end

    def create_aws_spot_instance(instance_params, spot_bid_price)
      @logger.info("Launching spot instance...")
      spot_manager = Bosh::AwsCloud::SpotManager.new(@ec2)

      spot_manager.create(instance_params, spot_bid_price)
    end

    def create_aws_instance(instance_params, resource_pool)
      if resource_pool["spot_bid_price"]
        begin
          return create_aws_spot_instance instance_params, resource_pool["spot_bid_price"]
        rescue Bosh::Clouds::VMCreationFailed => e
          raise unless resource_pool["spot_ondemand_fallback"]
        end
      end

      instance_params[:min_count] = 1
      instance_params[:max_count] = 1

      # Retry the create instance operation a couple of times if we are told that the IP
      # address is in use - it can happen when the director recreates a VM and AWS
      # is too slow to update its state when we have released the IP address and want to
      # realocate it again.
      errors = [AWS::EC2::Errors::InvalidIPAddress::InUse]
      Bosh::Common.retryable(sleep: instance_create_wait_time, tries: 10, on: errors) do |tries, error|
        @logger.info("Launching on demand instance...")
        if error.class == AWS::EC2::Errors::InvalidIPAddress::InUse
          @logger.warn("IP address was in use: #{error}")
        end
        resp = @ec2.client.run_instances(instance_params)
        @ec2.instances[get_created_instance_id(resp)]
      end
    end

    def get_created_instance_id(resp)
      resp.instances_set.first.instance_id
    end

    def instance_create_wait_time
      30
    end

    def subnet_az_mapping(networks_spec)
      subnet_networks = networks_spec.select { |net, spec| ["dynamic", "manual", nil].include?(spec["type"]) }
      subnet_ids = subnet_networks.values.map { |spec| spec["cloud_properties"]["subnet"] unless spec["cloud_properties"].nil? }
      filtered_subnets = @ec2.subnets.filter('subnet-id', subnet_ids)
      filtered_subnets.inject({}) do |mapping, subnet|
        mapping[subnet.id] = subnet.availability_zone.name
        mapping
      end
    end

    def sg_name_mapper
      Proc.new do |sg_names|
        return [] unless sg_names
        @ec2.security_groups.inject([]) do |security_group_ids, group|
          security_group_ids << group.security_group_id if sg_names.include?(group.name)
          security_group_ids
        end
      end
    end
  end
end
