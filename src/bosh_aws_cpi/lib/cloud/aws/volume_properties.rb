module Bosh
  module AwsCloud
    class VolumeProperties
      include Helpers

      attr_reader :size, :az, :iops, :type, :encrypted

      def initialize(options)
        @size = options[:size] || 0
        @type = options[:type] || 'gp2'
        @iops = options[:iops]
        @az = options[:az]
        @kms_key_arn = options[:kms_key_arn]
        @encrypted = options[:encrypted] || false
      end

      def ephemeral_disk_config
        mapping = {
          volume_size: size_in_gb,
          volume_type: @type,
          delete_on_termination: true,
        }

        mapping[:iops] = @iops if @iops
        mapping[:encrypted] = @encrypted if @encrypted

        { device_name: '/dev/sdb', ebs: mapping }
      end

      def persistent_disk_config
        output = {
          size: size_in_gb,
          availability_zone: @az,
          volume_type: @type,
          encrypted: @encrypted
        }

        output[:iops] = @iops if @iops
        output[:kms_key_id] = @kms_key_arn if @kms_key_arn
        output
      end

      private

      def size_in_gb
        (@size / 1024.0).ceil
      end
    end
  end
end
