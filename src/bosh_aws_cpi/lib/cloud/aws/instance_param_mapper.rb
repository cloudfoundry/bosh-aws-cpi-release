require 'json'

module Bosh::AwsCloud
  class InstanceParamMapper
    attr_accessor :manifest_params

    def initialize(logger)
      @manifest_params = {}
      @logger = logger
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

      unless missing_inputs.empty?
        raise Bosh::Clouds::CloudError, "Missing properties: #{missing_inputs.join(', ')}. See http://bosh.io/docs/aws-cpi.html for the list of supported properties."
      end
    end

    def validate_availability_zone
      # Check to see if provided availability zones match
      # For validation purposes, we can use nil for subnet_az since we're just checking configuration
      availability_zone(nil)
      true
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
        network_interfaces: network_interfaces.map.with_index { |nic, index| nic.nic_configuration(index) }
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

      az = availability_zone(network_interfaces.first.availability_zone)
      placement = {}
      placement[:group_name] = vm_type.placement_group if vm_type.placement_group
      placement[:availability_zone] = az if az
      placement[:tenancy] = vm_type.tenancy.dedicated if vm_type.tenancy.dedicated?
      params[:placement] = placement unless placement.empty?
      params.delete_if { |_k, v| v.nil? }
    end

    private

    def vm_type
      @manifest_params[:vm_type]
    end

    def iam_instance_profile
      { name: vm_type.iam_instance_profile } if vm_type.iam_instance_profile
    end

    def volume_zones
      @manifest_params[:volume_zones] || []
    end

    def availability_zone(subnet_az)
      az_selector = AvailabilityZoneSelector.new(nil)
      az_selector.common_availability_zone(
        volume_zones,
        vm_type.availability_zone,
        subnet_az
      )
    end
  end
end
