module Bosh::AwsCloud
  class StemcellCloudProps
    attr_reader :ami, :encrypted, :kms_key_arn
    attr_reader :disk, :architecture, :virtualization_type, :root_device_name, :kernel_id

    # @param [Hash] cloud_properties
    # @param [Bosh::AwsCloud::Config] global_config
    def initialize(cloud_properties, global_config)
      @global_config = global_config
      @cloud_properties = cloud_properties.merge(@global_config.aws.stemcell)

      @ami = @cloud_properties['ami']
      @encrypted = !!@cloud_properties['encrypted']
      @kms_key_arn = @cloud_properties['kms_key_arn']

      @name = @cloud_properties['name']
      @version = @cloud_properties['version']

      @disk = @cloud_properties['disk'] || DEFAULT_DISK_SIZE
      @architecture = @cloud_properties['architecture']
      @virtualization_type = @cloud_properties['virtualization_type'] || 'hvm'
      @root_device_name = @cloud_properties['root_device_name']
      @kernel_id = @cloud_properties['kernel_id']
    end

    # old stemcells doesn't have name & version
    def old?
      @name && @version
    end

    def formatted_name
      "#{@name} #{@version}"
    end

    def paravirtual?
      virtualization_type == PARAVIRTUAL
    end

    def is_light?
      !ami.nil? && !ami.empty?
    end

    def ami_ids
      ami.values
    end

    def region_ami
      ami[@global_config.aws.region]
    end

    def to_h
      @cloud_properties
    end

    private

    DEFAULT_DISK_SIZE = 2048
    PARAVIRTUAL = 'paravirtual'.freeze

  end

  class PropsFactory
    def initialize(config)
      @config = config
    end

    def stemcell_props(stemcell_properties)
      Bosh::AwsCloud::StemcellCloudProps.new(stemcell_properties, @config)
    end
  end
end