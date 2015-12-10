module Bosh::AwsCloud
  class AvailabilityZoneSelector
    attr_accessor :region

    def initialize(region, default_name)
      @region = region
      @default = default_name
    end

    def common_availability_zone(volume_az_names, resource_pool_az_name, vpc_subnet_az_name)
      zone_names = (volume_az_names + [resource_pool_az_name, vpc_subnet_az_name]).compact.uniq
      if zone_names.size > 1
        volume_az_error_string = ", and volume in #{volume_az_names.join(', ')}" unless volume_az_names.empty?
        raise Bosh::Clouds::CloudError, "can't use multiple availability zones: subnet in #{vpc_subnet_az_name}, VM in #{resource_pool_az_name}#{volume_az_error_string}"
      end

      zone_names.first || @default
    end

    def select_availability_zone(instance_id)
      if instance_id
        region.instances[instance_id].availability_zone
      elsif @default
        @default
      else
        random_availability_zone
      end
    end

    private

    def random_availability_zone
      zones = []
      region.availability_zones.each { |zone| zones << zone.name }
      zones[Random.rand(zones.size)]
    end
  end
end
