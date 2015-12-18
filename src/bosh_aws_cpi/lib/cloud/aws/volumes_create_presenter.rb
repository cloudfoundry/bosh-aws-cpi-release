module Bosh
  module AwsCloud
    class VolumesCreatePresenter
      attr_reader :volume_properties
      def initialize(volume_properties)
        @volume_properties = volume_properties
      end

      def present
        volume_options = {
          size: (volume_properties.size / 1024.0).ceil,
          availability_zone: volume_properties.az,
          volume_type: volume_properties.type,
          encrypted: volume_properties.encrypted
        }
        volume_options[:iops] = volume_properties.iops if volume_properties.iops
        volume_options
      end
    end
  end
end

