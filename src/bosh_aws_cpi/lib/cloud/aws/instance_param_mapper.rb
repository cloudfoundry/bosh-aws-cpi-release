require 'json'

module Bosh::AwsCloud
  class InstanceParamMapper
    attr_accessor :manifest_params

    def initialize
      @manifest_params = {}
    end

    def validate
      validate_required_inputs
      validate_security_groups
      validate_availability_zone
    end

    def validate_required_inputs
      required_top_level = [
        'stemcell_id',
        'registry_endpoint'
      ]
      required_resource_pool = [
        'instance_type',
        'availability_zone'
      ]
      missing_inputs = []

      required_top_level.each do |input_name|
        missing_inputs << input_name unless @manifest_params[input_name.to_sym]
      end
      required_resource_pool.each do |input_name|
        missing_inputs << "resource_pool.#{input_name}" unless resource_pool[input_name]
      end

      unless key_name
        missing_inputs << "(resource_pool.key_name or defaults.default_key_name)"
      end

      sg = security_groups
      if ( sg.nil? || sg.empty? )
        missing_inputs << "(resource_pool.security_groups or network security_groups or defaults.default_security_groups)"
      end

      if subnet_id.nil?
        missing_inputs << "networks_spec.[].cloud_properties.subnet_id"
      end

      unless missing_inputs.empty?
        raise Bosh::Clouds::CloudError, "Missing properties: #{missing_inputs.join(', ')}"
      end
    end

    def validate_security_groups
      sg = security_groups
      unless ( sg.nil? || sg.empty? )
        is_id = is_security_group_id?(sg.first)
        sg.drop(1).each do |group|
          unless is_security_group_id?(group) == is_id
            raise Bosh::Clouds::CloudError, 'security group names and ids can not be used together in security groups'
          end
        end
      end
    end

    def validate_availability_zone
      # Check to see if provided availability zones match
      availability_zone
    end

    def instance_params
      params = {
        min_count: 1,
        max_count: 1,
        image_id: @manifest_params[:stemcell_id],
        instance_type: resource_pool['instance_type'],
        key_name: key_name,
        iam_instance_profile: iam_instance_profile,
        user_data: user_data,
        block_device_mappings: @manifest_params[:block_device_mappings]
      }

      az = availability_zone
      placement = {}
      placement[:group_name] = resource_pool['placement_group'] if resource_pool['placement_group']
      placement[:availability_zone] = az if az
      placement[:tenancy] = 'dedicated' if resource_pool['tenancy'] == 'dedicated'
      params[:placement] = placement unless placement.empty?

      sg = security_groups
      if using_security_group_names?(sg)
        raise Bosh::Clouds::CloudError, 'sg_name_mapper must be provided when using security_group names' unless @manifest_params[:sg_name_mapper]
        sg = @manifest_params[:sg_name_mapper].call(sg)
      end

      nic = {}
      nic[:groups] = sg unless sg.nil? || sg.empty?
      nic[:subnet_id] = subnet_id if subnet_id
      nic[:private_ip_address] = private_ip_address if private_ip_address
      nic[:device_index] = 0 unless nic.empty?
      params[:network_interfaces] = [nic] unless nic.empty?

      params.delete_if { |k, v| v.nil? }
    end

    private

    def is_security_group_id?(security_group)
      security_group.start_with?('sg-') && security_group.size == 11
    end

    def using_security_group_names?(security_groups)
      return false if security_groups.nil? || security_groups.empty?
      return false if is_security_group_id?(security_groups.first)
      true
    end

    def resource_pool
      @manifest_params[:resource_pool] || {}
    end

    def networks_spec
      @manifest_params[:networks_spec] || {}
    end

    def defaults
      @manifest_params[:defaults] || {}
    end

    def volume_zones
      @manifest_params[:volume_zones] || []
    end

    def subnet_az_mapping
      @manifest_params[:subnet_az_mapping] || {}
    end

    def key_name
      resource_pool["key_name"] || defaults["default_key_name"]
    end

    def iam_instance_profile
      profile_name = resource_pool["iam_instance_profile"] || defaults["default_iam_instance_profile"]
      { name: profile_name } if profile_name
    end

    def security_groups
      groups = resource_pool["security_groups"] || extract_security_groups(networks_spec)
      groups.empty? ? defaults["default_security_groups"] : groups
    end

    def user_data
      user_data = {}
      user_data[:registry] = { endpoint: @manifest_params[:registry_endpoint] } if @manifest_params[:registry_endpoint]

      spec_with_dns = networks_spec.values.select { |spec| spec.has_key? "dns" }.first
      user_data[:dns] = {nameserver: spec_with_dns["dns"]} if spec_with_dns

      Base64.encode64(user_data.to_json).strip unless user_data.empty?
    end

    def private_ip_address
      manual_network_spec = networks_spec.values.select do |spec|
        ["manual", nil].include?(spec["type"])
      end.first || {}
      manual_network_spec["ip"]
    end

    # NOTE: do NOT lookup the subnet (from EC2 client) anymore. We just need to
    # pass along the subnet_id anyway, and we have that.
    def subnet_id
      subnet_network_spec = networks_spec.values.select do |spec|
        ["manual", nil, "dynamic"].include?(spec["type"]) &&
          spec.fetch("cloud_properties", {}).has_key?("subnet")
      end.first

      subnet_network_spec["cloud_properties"]["subnet"] if subnet_network_spec
    end

    def availability_zone
      az_selector = AvailabilityZoneSelector.new(nil)
      az_selector.common_availability_zone(
        volume_zones,
        resource_pool["availability_zone"],
        subnet_az_mapping[subnet_id]
      )
    end

    def extract_security_groups(networks_spec)
      networks_spec.
          values.
          select { |network_spec| network_spec.has_key? "cloud_properties" }.
          map { |network_spec| network_spec["cloud_properties"] }.
          select { |cloud_properties| cloud_properties.has_key? "security_groups" }.
          map { |cloud_properties| Array(cloud_properties["security_groups"]) }.
          flatten.
          sort.
          uniq
    end

  end
end
