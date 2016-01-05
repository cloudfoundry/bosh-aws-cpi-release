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
            cloud_error('AWS CPI minimum disk size is 1 GiB') if @size < 1024
            cloud_error('AWS CPI maximum disk size is 1 TiB') if @size > 1024 * 1000
            cloud_error("Cannot specify an 'iops' value when disk type is '#{@type}'. 'iops' is only allowed for 'io1' volume types.") unless @iops.nil?
          when 'gp2'
            cloud_error('AWS CPI minimum disk size is 1 GiB') if @size < 1024
            cloud_error('AWS CPI maximum disk size is 16 TiB') if @size > 1024 * 16000
            cloud_error("Cannot specify an 'iops' value when disk type is '#{@type}'. 'iops' is only allowed for 'io1' volume types.") unless @iops.nil?
          when 'io1'
            validate_iops
          else
            cloud_error("AWS CPI supports only gp2, io1, or standard disk type, received: #{@type}")
        end
      end

      private

      def validate_iops
        cloud_error("Must specify an 'iops' value when the volume type is 'io1'") if @iops.nil?
        cloud_error('AWS CPI minimum disk size is 4 GiB') if @size < 1024 * 4
        cloud_error('AWS CPI maximum disk size is 16 TiB') if @size > 1024 * 16000
        cloud_error('AWS CPI maximum iops is 20000') if @iops >= 20000
        cloud_error('AWS CPI maximum ratio iops/size is 30') if (@iops / (@size / 1024)).floor >= 30
      end
    end
  end
end
