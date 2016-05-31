module Bosh
  module AwsCloud
    class VolumeProperties
      include Helpers

      attr_reader :size, :az, :iops, :type, :encrypted

      def initialize(options)
        @size = options[:size] || 0
        @type = options[:type] || 'standard'
        @iops = options[:iops]
        @az = options[:az]
        @encrypted = options[:encrypted] || false
      end

      def disk_mapping
        mapping = {
          volume_size: size_in_gb,
          volume_type: @type,
          delete_on_termination: true,
        }

        mapping[:iops] = @iops if @iops
        mapping[:encrypted] = @encrypted if @encrypted

        { device_name: '/dev/sdb', ebs: mapping }
      end

      def volume_options
        options = {
          size: size_in_gb,
          availability_zone: @az,
          volume_type: @type,
          encrypted: @encrypted
        }

        options[:iops] = @iops if @iops
        options
      end

      private

      def size_in_gb
        (@size / 1024.0).ceil
      end
    end
  end
end
