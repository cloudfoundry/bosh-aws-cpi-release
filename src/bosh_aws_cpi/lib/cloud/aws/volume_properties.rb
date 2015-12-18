module Bosh
  module AwsCloud
    class VolumeProperties
      include Helpers

      attr_reader :size, :type, :iops, :az, :encrypted

      def initialize(options)
        @size = options[:size]
        @type = options[:type] || 'standard'
        @iops = options[:iops]
        @az = options[:az]
        @encrypted = options[:encrypted] || false
      end

      def validate!
        unless %w[gp2 standard io1].include?(@type)
          cloud_error('AWS CPI supports only gp2, io1, or standard disk type')
        end

        cloud_error('AWS CPI minimum disk size is 1 GiB') if @size < 1024
        if @type == 'standard'
          cloud_error('AWS CPI maximum disk size is 1 TiB') if @size > 1024 * 1000
        else
          cloud_error('AWS CPI maximum disk size is 16 TiB') if @size > 1024 * 16000
        end

        case @type
          when 'io1'
            error = "Must specify an 'iops' value when the volume type is 'io1'"
            cloud_error(error) if @iops.nil?
          else
            error = "Cannot specify an 'iops' value when disk type is '#{@type}'. 'iops' is only allowed for 'io1' volume types."
            cloud_error(error) unless @iops.nil?
        end
      end
    end
  end
end
