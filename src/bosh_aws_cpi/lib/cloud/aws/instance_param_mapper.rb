require 'json'

module Bosh::AwsCloud
  class InstanceParamMapper
    attr_accessor :manifest_params

    def initialize(security_group_mapper)
      @manifest_params = {}
      @security_group_mapper = security_group_mapper
    end

    def validate
      validate_required_inputs
      validate_availability_zone
    end

    def validate_required_inputs
      required_top_level = [
        'stemcell_id',
        'registry_endpoint'
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

      unless vm_type.key_name
        missing_inputs << '(cloud_properties.key_name or global default_key_name)'
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
      params = {
        image_id: @manifest_params[:stemcell_id],
        instance_type: vm_type.instance_type,
        key_name: vm_type.key_name,
        iam_instance_profile: iam_instance_profile,
        user_data: user_data,
        block_device_mappings: @manifest_params[:block_device_mappings]
      }

      az = availability_zone
      placement = {}
      placement[:group_name] = vm_type.placement_group if vm_type.placement_group
      placement[:availability_zone] = az if az
      placement[:tenancy] = vm_type.tenancy.dedicated if vm_type.tenancy.dedicated?
      params[:placement] = placement unless placement.empty?

      sg = @security_group_mapper.map_to_ids(security_groups, subnet_id)

      nic = {}
      nic[:groups] = sg unless sg.nil? || sg.empty?
      nic[:subnet_id] = subnet_id if subnet_id

      # Only supporting one IP address for now (either IPv4 or IPv6)
      if private_ip_address
        if ipv6_address?(private_ip_address)
          nic[:ipv_6_addresses] = [{ipv_6_address: private_ip_address}]
        else
          nic[:private_ip_address] = private_ip_address
        end
      end

      nic[:associate_public_ip_address] = vm_type.auto_assign_public_ip if vm_type.auto_assign_public_ip

      nic[:device_index] = 0 unless nic.empty?
      params[:network_interfaces] = [nic] unless nic.empty?

      params.delete_if { |k, v| v.nil? }
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

    def user_data
      user_data = {}
      user_data[:registry] = { endpoint: @manifest_params[:registry_endpoint] } if @manifest_params[:registry_endpoint]

      network_with_dns = networks_cloud_props.dns_networks.first
      user_data[:dns] = { nameserver: network_with_dns.dns } unless network_with_dns.nil?

      # If IPv6 network is present then send network setting up front so that agent can reconfigure networking stack
      user_data[:networks] = Bosh::AwsCloud::AgentSettings.agent_network_spec(networks_cloud_props) unless networks_cloud_props.ipv6_networks.empty?

      Base64.encode64(user_data.to_json).strip unless user_data.empty?
    end

    def ipv6_address?(addr)
      addr.to_s.include?(':')
    end

    def private_ip_address
      first_manual_network = networks_cloud_props.filter('manual').first
      first_manual_network.ip unless first_manual_network.nil?
    end

    # NOTE: do NOT lookup the subnet (from EC2 client) anymore. We just need to
    # pass along the subnet_id anyway, and we have that.
    def subnet_id
      subnet_network_spec = networks_cloud_props.filter('manual', 'dynamic').reject do |net|
        net.subnet.nil?
      end.first

      subnet_network_spec.subnet unless subnet_network_spec.nil?
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
