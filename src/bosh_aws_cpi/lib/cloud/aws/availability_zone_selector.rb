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
        raise Bosh::Clouds::CloudError,
          "can't use multiple availability zones: Volume in #{volume_az_names.first}, " +
              "Resource Pool in #{resource_pool_az_name}, " +
              "Subnet in #{vpc_subnet_az_name}"
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
