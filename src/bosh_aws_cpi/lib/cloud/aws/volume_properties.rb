module Bosh
  module AwsCloud
    class VolumeProperties
      include Helpers

      attr_reader :size, :type, :iops, :az, :encrypted

      def initialize(options)
        @size = options[:size] || 0
        @type = options[:type] || 'standard'
        @iops = options[:iops]
        @az = options[:az]
        @encrypted = options[:encrypted] || false
      end

      def validate!
        case @type
          when 'standard'
            cloud_error("Cannot specify an 'iops' value when disk type is '#{@type}'. 'iops' is only allowed for 'io1' volume types.") unless @iops.nil?
          when 'gp2'
            cloud_error("Cannot specify an 'iops' value when disk type is '#{@type}'. 'iops' is only allowed for 'io1' volume types.") unless @iops.nil?
          when 'io1'
            cloud_error("Must specify an 'iops' value when the volume type is 'io1'") if @iops.nil?
          else
            cloud_error("AWS CPI supports only gp2, io1, or standard disk type, received: #{@type}")
        end
        cloud_error("AWS CPI disk size must be greater than 0") if @size <= 0
      end
    end
  end
end
