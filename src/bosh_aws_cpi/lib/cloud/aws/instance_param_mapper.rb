require 'json'

module Bosh::AwsCloud
  class InstanceParamMapper
    attr_accessor :manifest_params

    def initialize(security_group_mapper, logger)
      @manifest_params = {}
      @logger = logger
      @security_group_mapper = security_group_mapper
    end

    def validate
      validate_required_inputs
      validate_availability_zone
    end

    def validate_required_inputs
      required_top_level = [
        'stemcell_id',
        'user_data'
      ]
      required_vm_type = [
        'instance_type',
        'availability_zone'
      ]
      missing_inputs = []

      required_top_level.each do |input_name|
        missing_inputs << input_name unless @manifest_params[input_name.to_sym]
      end
      required_vm_type.each do |input_name|
        if vm_type.respond_to?(input_name)
          missing_inputs << "cloud_properties.#{input_name}" unless vm_type.public_send(input_name)
        end
      end

      sg = security_groups
      if ( sg.nil? || sg.empty? )
        missing_inputs << '(cloud_properties.security_groups or global default_security_groups)'
      end

      if subnet_id.nil?
        missing_inputs << 'cloud_properties.subnet_id'
      end

      unless missing_inputs.empty?
        raise Bosh::Clouds::CloudError, "Missing properties: #{missing_inputs.join(', ')}. See http://bosh.io/docs/aws-cpi.html for the list of supported properties."
      end
    end

    def validate_availability_zone
      # Check to see if provided availability zones match
      availability_zone
    end

    def instance_params
      if @manifest_params[:metadata_options].nil? && vm_type.metadata_options.empty?
        metadata_options = nil
      else
        metadata_options = (@manifest_params[:metadata_options] || {}).merge(vm_type.metadata_options)
      end
      params = {
        image_id: @manifest_params[:stemcell_id],
        instance_type: vm_type.instance_type,
        key_name: vm_type.key_name,
        iam_instance_profile: iam_instance_profile,
        user_data: @manifest_params[:user_data],
        block_device_mappings: @manifest_params[:block_device_mappings],
        metadata_options: metadata_options
      }
      unless @manifest_params[:tags].nil? || @manifest_params[:tags].empty?
        params.merge!(
          tag_specifications: [
            {
              resource_type: 'instance',
              tags: @manifest_params[:tags].map { |k, v| { key: k, value: v } }
            }
          ]
        )
      end

      az = availability_zone
      placement = {}
      placement[:group_name] = vm_type.placement_group if vm_type.placement_group
      placement[:availability_zone] = az if az
      placement[:tenancy] = vm_type.tenancy.dedicated if vm_type.tenancy.dedicated?
      params[:placement] = placement unless placement.empty?

      sg = @security_group_mapper.map_to_ids(security_groups, subnet_id)

      nic = {}
      nic[:groups] = sg unless sg.nil? || sg.empty?
      nic[:subnet_id] = subnet_id

      if dual_stack_mode?
        ipv6_count = ipv4_count = 0
        private_ip_addresses.each do |private_ip|
          if ipv6_address?(private_ip)
            nic[:ipv_6_addresses] = [{ipv_6_address: private_ip}]
            ipv6_count += 1
          else
            nic[:private_ip_address] = private_ip
            ipv4_count += 1
          end
        end
        if ipv4_count == 1 && ipv6_count == 1
          @logger.info("Running in dual stack mode")
        else
          if ipv4_count == 0
            raise Bosh::Clouds::CloudError, "Dual Stack Mode: No ipv4 address assigned"
          elsif ipv6_count == 0
            raise Bosh::Clouds::CloudError, "Dual Stack Mode: No ipv6 address assigned"
          end
        end
      else
        private_ip_address = private_ip_addresses.first
        if private_ip_address
          if ipv6_address?(private_ip_address)
            nic[:ipv_6_addresses] = [{ipv_6_address: private_ip_address}]
          else
            nic[:private_ip_address] = private_ip_address
          end
        end
      end

      nic[:associate_public_ip_address] = vm_type.auto_assign_public_ip unless vm_type.auto_assign_public_ip.nil?

      nic[:device_index] = 0 unless nic.empty?
      params[:network_interfaces] = [nic] unless nic.empty?

      params.delete_if { |_k, v| v.nil? }
    end

    private

    def vm_type
      @manifest_params[:vm_type]
    end
    def networks_cloud_props
      @manifest_params[:networks_spec]
    end

    def default_security_groups
      @manifest_params[:default_security_groups] || []
    end

    def volume_zones
      @manifest_params[:volume_zones] || []
    end

    def subnet_az_mapping
      @manifest_params[:subnet_az_mapping] || {}
    end

    def iam_instance_profile
      { name: vm_type.iam_instance_profile } if vm_type.iam_instance_profile
    end

    def security_groups
      networks_security_groups = networks_cloud_props.security_groups

      groups = default_security_groups
      groups = networks_security_groups unless networks_security_groups.empty?
      groups = vm_type.security_groups unless vm_type.security_groups.empty?
      groups
    end

    def ipv6_address?(addr)
      addr.to_s.include?(':')
    end

    def private_ip_addresses
      ips = subnets.map { |subnet_network| subnet_network.ip }

      ips unless ips.nil?
    end

    # NOTE: do NOT lookup the subnet (from EC2 client) anymore. We just need to
    # pass along the subnet_id anyway, and we have that.
    def subnets
      subnet_network_specs = networks_cloud_props.filter('manual', 'dynamic').reject do |net|
        net.subnet.nil?
      end

      subnet_network_specs unless subnet_network_specs.nil?
    end

    def subnet_id
      subnet_ids.first
    end

    def subnet_ids
      subnets.map { |subnet_network| subnet_network.subnet }
    end

    def dual_stack_mode?
      dual_stack_mode = false
      if subnets.length == 2
          # if two networks refer to the same subnet we assume dual stack mode
        if subnet_ids[0] == subnet_ids[1]
          dual_stack_mode = true
        else
          raise Bosh::Clouds::CloudError, "Dual Stack Mode: Subnet #{subnet_ids[0]} and subnet #{subnet_ids[1]} are different"
        end
      end
      dual_stack_mode
    end

    def availability_zone
      az_selector = AvailabilityZoneSelector.new(nil)
      az_selector.common_availability_zone(
        volume_zones,
        vm_type.availability_zone,
        subnet_az_mapping[subnet_id]
      )
    end
  end
end
