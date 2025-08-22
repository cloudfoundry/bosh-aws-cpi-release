require 'common/common'
require 'time'

module Bosh::AwsCloud
  class AbruptlyTerminated < Bosh::Clouds::CloudError; end
  class InstanceManager
    include Helpers

    def initialize(ec2, logger)
      @ec2 = ec2
      @logger = logger
      @imds_v2_enable = {}
      @param_mapper = InstanceParamMapper.new(logger)
    end

    def create(stemcell_id, vm_cloud_props, networks_cloud_props, disk_locality, default_security_groups, block_device_mappings, settings, tags, metadata_options, stemcell_api_version)
      abruptly_terminated_retries = 2
      begin

        security_group_mapper = SecurityGroupMapper.new(@ec2)
        network_interface_manager = Bosh::AwsCloud::NetworkInterfaceManager.new(@ec2, @logger, security_group_mapper)
        network_interfaces = network_interface_manager.create_network_interfaces(networks_cloud_props, vm_cloud_props, default_security_groups)

        set_manifest_params(stemcell_id, vm_cloud_props, block_device_mappings, settings.encode(stemcell_api_version), disk_locality, tags, metadata_options)

        @param_mapper.update_user_data(settings.encode(stemcell_api_version))

        @param_mapper.validate
      rescue => e
        @logger.error("Failed to create network interfaces: #{e.inspect}")
        network_interfaces&.each { |nic| nic[:nic].delete }
        raise
      end

      begin
        instance_params  = @param_mapper.instance_params(network_interfaces)

        redacted_instance_params = Bosh::Cpi::Redactor.clone_and_redact(
          instance_params,
          'user_data',
          'defaults.access_key_id',
          'defaults.secret_access_key'
        )
        @logger.info("Creating new instance with: #{redacted_instance_params.inspect}")

        aws_instance = create_aws_instance(instance_params, vm_cloud_props)
        instance = Bosh::AwsCloud::Instance.new(aws_instance, @logger)

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

      instance
    end

    # @param [String] instance_id EC2 instance id
    def find(instance_id)
      Bosh::AwsCloud::Instance.new(@ec2.instance(instance_id), @logger)
    end

    private

    def set_manifest_params(stemcell_id, vm_cloud_props, block_device_mappings, user_data, disk_locality = [], tags, metadata_options)
      volume_zones = (disk_locality || []).map { |volume_id| @ec2.volume(volume_id).availability_zone }
      @param_mapper.manifest_params = {
        stemcell_id: stemcell_id,
        vm_type: vm_cloud_props,
        volume_zones: volume_zones,
        subnet_az_mapping: subnet_az_mapping(networks_cloud_props),
        block_device_mappings: block_device_mappings,
        tags: tags,
        user_data: user_data,
        metadata_options: metadata_options,
      }
    end

    def babysit_instance_creation(instance, vm_cloud_props)
      begin
        # We need to wait here for the instance to be running, as if we are going to
        # attach to a load balancer, the instance must be running.
        instance.wait_until_exists
        instance.wait_until_running
        instance.update_routing_tables(vm_cloud_props.advertised_routes)
        instance.disable_dest_check unless vm_cloud_props.source_dest_check
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

    def create_aws_spot_instance(launch_specification, spot_bid_price)
      @logger.info('Launching spot instance...')
      spot_manager = Bosh::AwsCloud::SpotManager.new(@ec2)

      spot_manager.create(launch_specification, spot_bid_price)
    end

    def create_aws_instance(instance_params, vm_cloud_props)
      if vm_cloud_props.spot_bid_price
        begin
          return create_aws_spot_instance(instance_params, vm_cloud_props.spot_bid_price)
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

      @logger.info('Launching on demand instance...')
      resp = @ec2.client.run_instances(instance_params)
      @ec2.instance(get_created_instance_id(resp))
    end

    def get_created_instance_id(resp)
      resp.instances.first.instance_id
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
