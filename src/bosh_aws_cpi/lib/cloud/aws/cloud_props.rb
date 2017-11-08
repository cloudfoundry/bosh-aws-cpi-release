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

      @encrypted = @global_config.aws.encrypted
      @encrypted = !!@cloud_properties['encrypted'] if @cloud_properties.key?('encrypted')

      @kms_key_arn = @global_config.aws.kms_key_arn
      @kms_key_arn = @cloud_properties['kms_key_arn'] if @cloud_properties.key?('kms_key_arn')

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

    private

    DEFAULT_DISK_SIZE = 2048
    PARAVIRTUAL = 'paravirtual'.freeze

  end

  class DiskCloudProps
    attr_reader :type, :iops, :encrypted, :kms_key_arn

    # @param [Hash] cloud_properties
    # @param [Bosh::AwsCloud::Config] global_config
    def initialize(cloud_properties, global_config)
      @type = cloud_properties['type']
      @iops = cloud_properties['iops']

      @encrypted = global_config.aws.encrypted
      @encrypted = !!cloud_properties['encrypted'] if cloud_properties.key?('encrypted')

      @kms_key_arn = global_config.aws.kms_key_arn
      @kms_key_arn = cloud_properties['kms_key_arn'] if cloud_properties.key?('kms_key_arn')
    end
  end

  class VMCloudProps
    attr_reader :instance_type, :availability_zone, :security_groups, :key_name
    attr_reader :spot_bid_price, :spot_ondemand_fallback, :iam_instance_profile
    attr_reader :placement_group, :tenancy, :auto_assign_public_ip, :elbs
    attr_reader :lb_target_groups, :advertised_routes, :raw_instance_storage
    attr_reader :ephemeral_disk, :root_disk

    # @param [Hash] cloud_properties
    # @param [Bosh::AwsCloud::Config] global_config
    def initialize(cloud_properties, global_config)
      @cloud_properties = cloud_properties.dup

      @instance_type = cloud_properties['instance_type']
      @availability_zone = cloud_properties['availability_zone']
      @security_groups = cloud_properties['security_groups'] || []
      @key_name = cloud_properties['key_name'] || global_config.aws.default_key_name
      @spot_bid_price = cloud_properties['spot_bid_price']
      @spot_ondemand_fallback = !!cloud_properties['spot_ondemand_fallback'] || false
      @elbs = cloud_properties['elbs'] || []
      @lb_target_groups = cloud_properties['lb_target_groups'] || []
      @iam_instance_profile = cloud_properties['iam_instance_profile'] || global_config.aws.default_iam_instance_profile
      @placement_group = cloud_properties['placement_group']
      @tenancy = cloud_properties['tenancy'] || 'default'
      @auto_assign_public_ip = !!cloud_properties['auto_assign_public_ip'] || false
      @advertised_routes = (cloud_properties['advertised_routes'] || []).map do |route|
        AdvertisedRoute.new(route)
      end
      @raw_instance_storage = !!cloud_properties['raw_instance_storage'] || false
      @source_dest_check = !!cloud_properties['source_dest_check'] || true

      # encrypted = global_config.aws.encrypted
      # if encrypted
      #   if @cloud_properties['ephemeral_disk']
      #     if @cloud_properties['ephemeral_disk'].key?('encrypted')
      #       encrypted = !!@cloud_properties['ephemeral_disk']['encrypted']
      #     end
      #     @cloud_properties['ephemeral_disk']['encrypted'] = encrypted
      #   else
      #     @cloud_properties['ephemeral_disk'] = {
      #       'encrypted' => encrypted
      #     }
      #   end
      # end

      @ephemeral_disk = EphemeralDisk.new(@cloud_properties['ephemeral_disk'], global_config)
      @cloud_properties['ephemeral_disk'] = @ephemeral_disk.disk if !@ephemeral_disk.disk.nil?

      @root_disk = RootDisk.new(@cloud_properties['root_disk'])
      @cloud_properties['root_disk'] = @root_disk.disk if !@root_disk.disk.nil?
    end

    def to_h
      @cloud_properties
    end

    class AdvertisedRoute
      attr_reader :table_id, :destination

      def initialize(advertised_route)
        @table_id = advertised_route['table_id']
        @destination = advertised_route['destination']
      end
    end

    class Disk
      attr_reader :size, :type, :iops, :disk

      def initialize(disk)
        if disk
          @disk = disk.dup

          @size = disk['size']
          @type = disk['type']
          @iops = disk['ios']
        end
      end

      def specified?
        !disk.key?['size']
      end
    end

    class EphemeralDisk < Disk
      attr_reader :size, :type, :iops, :use_instance_storage, :encrypted

      def initialize(ephemeral_disk, global_config)
        super(ephemeral_disk)

        if ephemeral_disk
          @use_instance_storage = !!ephemeral_disk['use_instance_storage'] || false
        end

        @encrypted = global_config.aws.encrypted
        if @encrypted
          if ephemeral_disk
            if ephemeral_disk.key?('encrypted')
              @encrypted = !!ephemeral_disk['encrypted']
            end
            ephemeral_disk['encrypted'] = @encrypted
          else
            @disk.merge!('encrypted' => @encrypted)
          end
        end
      end
    end

    class RootDisk < Disk
    end
  end

  class PropsFactory
    def initialize(config)
      @config = config
    end

    def stemcell_props(stemcell_properties)
      Bosh::AwsCloud::StemcellCloudProps.new(stemcell_properties, @config)
    end

    def disk_props(disk_properties)
      Bosh::AwsCloud::DiskCloudProps.new(disk_properties, @config)
    end

    def vm_props(vm_properties)
      Bosh::AwsCloud::VMCloudProps.new(vm_properties, @config)
    end
  end
end