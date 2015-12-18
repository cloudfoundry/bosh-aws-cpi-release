module Bosh
  module AwsCloud
    class InstancesCreatePresenter
      attr_reader :volume_properties
      def initialize(volume_properties)
        @volume_properties = volume_properties
      end

      def present
        ebs = {
          volume_size: volume_size_in_gb,
          volume_type: volume_properties.type,
          delete_on_termination: true,
        }

        ebs[:iops] = volume_properties.iops if volume_properties.iops

        [{device_name: '/dev/sdb', ebs: ebs}]
      end

      private

      def volume_size_in_gb
        (volume_properties.size / 1024.0).ceil
      end
    end
  end
end

