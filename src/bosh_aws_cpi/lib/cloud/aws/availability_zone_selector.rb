module Bosh::AwsCloud
  class AvailabilityZoneSelector
    attr_accessor :resource

    def initialize(resource)
      @resource = resource
    end

    def common_availability_zone(volume_az_names, vm_type_az_name, vpc_subnet_az_name)
      zone_names = (volume_az_names + [vm_type_az_name, vpc_subnet_az_name]).compact.uniq
      if zone_names.size > 1
        volume_az_error_string = ", and volume in #{volume_az_names.join(', ')}" unless volume_az_names.empty?
        raise Bosh::Clouds::CloudError, "can't use multiple availability zones: subnet in #{vpc_subnet_az_name}, VM in #{vm_type_az_name}#{volume_az_error_string}"
      end

      zone_names.first
    end

    def select_availability_zone(instance_id)
      if instance_id
        resource.instance(instance_id).placement.availability_zone
      else
        random_availability_zone
      end
    end

    private

    def random_availability_zone
      zones = []
      resource.client.describe_availability_zones['availability_zones'].each { |az| zones << az['zone_name']}
      zones[Random.rand(zones.size)]
    end
  end
end
