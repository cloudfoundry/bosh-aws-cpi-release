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

    def update_user_data(user_data)
      @manifest_params[:user_data] = user_data
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

    def network_interface_params
      nic_groups = group_networks_by_nic_group(subnets)
      validate_nic_groups_subnets(nic_groups)
      updated_nic_groups = assign_ip_configs_to_nic_groups(nic_groups)
      build_network_interfaces_from_groups(updated_nic_groups)
    end

    def instance_params(network_interfaces)
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
        metadata_options: metadata_options,
        network_interfaces: network_interfaces.map { |nic| nic[:nic].configuration }
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
      params.delete_if { |_k, v| v.nil? }
    end

    def ipv6_address?(addr)
      addr.to_s.include?(':')
    end

    private

    def group_networks_by_nic_group(subnets)
      nic_groups = Hash.new { |h, k| h[k] = [] }
      subnets.each do |net|
        group_key = net.to_h['nic_group'] || net.name
        nic_groups[group_key] << net
      end
      nic_groups
    end

    def validate_nic_groups_subnets(nic_groups)
      nic_groups.each do |nic_group, nets|
        subnet_ids = nets.map { |net| net.subnet }.compact.uniq
        if subnet_ids.size > 1
          raise Bosh::Clouds::CloudError, "Networks in nic_group '#{nic_group}' have different subnet_ids: #{subnet_ids.join(', ')}. All networks in a nic_group must have the same subnet_id."
        end
      end
    end

    def assign_ip_configs_to_nic_groups(nic_groups)
      nic_groups.each do |_nic_group, nets|
        ip_entries = nets.filter_map do |net|
          ip_value = net.to_h['ip']
          next unless ip_value
          
          entry = {}
          entry[:ip] = ip_value
          entry[:prefix] = net.to_h['prefix'] if net.to_h['prefix']
          entry[:name] = net.name
          entry
        end

        # Separate IPv4 and IPv6 addresses with standard prefixes (32 for IPv4, 128 for IPv6)
        ipv4_addresses = ip_entries.select { |entry| !ipv6_address?(entry[:ip]) && (entry[:prefix].to_s.empty? || entry[:prefix].to_i == 32) }
        ipv6_addresses = ip_entries.select { |entry| ipv6_address?(entry[:ip]) && (entry[:prefix].to_s.empty? || entry[:prefix].to_i == 128) }
        
        # Separate IPv4 and IPv6 prefixes (non-standard prefix lengths)
        ipv4_prefixes = ip_entries.select { |entry| !ipv6_address?(entry[:ip]) && entry[:prefix] && entry[:prefix].to_i != 32 }
        ipv6_prefixes = ip_entries.select { |entry| ipv6_address?(entry[:ip]) && entry[:prefix] && entry[:prefix].to_i != 128 }

        # Validate AWS constraints: max 1 of each type per network interface
        if ipv4_addresses.size > 1 || ipv6_addresses.size > 1 || ipv4_prefixes.size > 1 || ipv6_prefixes.size > 1
          raise Bosh::Clouds::CloudError, "Network interface in nic_group #{nic_group} cannot have more than 1 IPv4/IPv6/PrefixV6/PrefixV4 defined all together. Please check the network configuration."
        end

        # Build consolidated IP configuration
        ip_config = {}
        ip_config[:private_ip_address] = ipv4_addresses.first[:ip] if ipv4_addresses.any?
        ip_config[:ipv6_address] = ipv6_addresses.first[:ip] if ipv6_addresses.any?
        ip_config[:prefix_v4] = { address: ipv4_prefixes.first[:ip], prefix: ipv4_prefixes.first[:prefix] } if ipv4_prefixes.any?
        ip_config[:prefix_v6] = { address: ipv6_prefixes.first[:ip], prefix: ipv6_prefixes.first[:prefix] } if ipv6_prefixes.any?
        ip_config[:network_names] = [
          (ipv4_addresses.first[:name] if ipv4_addresses.any?),
          (ipv6_addresses.first[:name] if ipv6_addresses.any?),
          (ipv4_prefixes.first[:name] if ipv4_prefixes.any?),
          (ipv6_prefixes.first[:name] if ipv6_prefixes.any?)
        ].compact

        nets.first.instance_variable_set(:@ip_config, ip_config) unless ip_config.empty?
      end

      nic_groups
    end

    def build_network_interfaces_from_groups(nic_groups)
      network_interfaces = []
      nic_groups.each_value do |nets|
        subnet_id_val = nets.first.subnet
        ip_config = nets.first.instance_variable_get(:@ip_config) || {}
        next if ip_config[:network_names].nil? || ip_config[:network_names].empty?
        nic = build_network_interface_params(subnet_id_val, ip_config)
        network_interfaces << nic if nic
      end
      network_interfaces
    end

    def build_network_interface_params(subnet_id_val, ip_config)
      sg = @security_group_mapper.map_to_ids(security_groups, subnet_id_val)

      nic = {}
      nic[:groups] = sg unless sg.nil? || sg.empty?
      nic[:subnet_id] = subnet_id_val
      nic[:ipv_6_addresses] = [{ ipv_6_address: ip_config[:ipv6_address] }] if ip_config[:ipv6_address]
      nic[:private_ip_address] = ip_config[:private_ip_address] if ip_config[:private_ip_address]
      
      prefixes = {}
      prefixes[:ipv4] = ip_config[:prefix_v4] if ip_config[:prefix_v4]
      prefixes[:ipv6] = ip_config[:prefix_v6] if ip_config[:prefix_v6]

      { nic: nic, prefixes: prefixes.empty? ? nil : prefixes, networks: ip_config[:network_names] || [] }
    end

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
