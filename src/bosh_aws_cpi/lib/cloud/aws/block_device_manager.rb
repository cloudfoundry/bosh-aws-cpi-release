
module Bosh::AwsCloud
  class BlockDeviceManager
    attr_writer :resource_pool
    attr_writer :virtualization_type

    DEFAULT_VIRTUALIZATION_TYPE = :hvm

    def self.default_instance_storage_disk_mapping
      { device_name: '/dev/sdb', virtual_name: 'ephemeral0' }
    end

    def initialize(logger)
      @virtualization_type = DEFAULT_VIRTUALIZATION_TYPE
      @logger = logger
    end

    def mappings
      if @info.nil?
        @info = build_info
      end

      @info.map { |entry| entry.reject { |k| k == :bosh_type } }
    end

    def agent_info
      if @info.nil?
        @info = build_info
      end

      @info.group_by { |v| v[:bosh_type] }
        .map { |type, devices| {type => devices.map { |device| {"path" => device[:device_name]} }} }
        .inject({}) { |a, b| a.merge(b) }
    end

    def build_info
      instance_type = @resource_pool.fetch('instance_type', 'unspecified')

      disk_info = DiskInfo.for(instance_type)
      if raw_instance_storage? && disk_info.nil?
        raise Bosh::Clouds::CloudError, "raw_instance_storage requested for instance type '#{instance_type}' that does not have instance storage"
      end

      block_devices = []
      block_devices << ephemeral_disk_mapping(instance_type, disk_info)

      if raw_instance_storage?
        block_devices += raw_instance_mappings(disk_info.count)
      end

      if @resource_pool.has_key?('root_disk')
        block_devices << root_disk_mapping
      end

      block_devices
    end

    private

    def ephemeral_disk_mapping(instance_type, disk_info)
      disk_options = @resource_pool.fetch("ephemeral_disk", {})

      if disk_options['use_instance_storage']
        if raw_instance_storage?
          raise Bosh::Clouds::CloudError, "ephemeral_disk.use_instance_storage and raw_instance_storage cannot both be true"
        end

        if disk_options.size > 1
          raise Bosh::Clouds::CloudError, "use_instance_storage cannot be combined with additional ephemeral_disk properties"
        end

        if disk_info.nil?
          raise Bosh::Clouds::CloudError, "use_instance_storage requested for instance type '#{instance_type}' that does not have instance storage"
        end

        @logger.debug('Use instance storage to create the virtual machine')
        result = BlockDeviceManager.default_instance_storage_disk_mapping
      else
        @logger.debug('Use EBS storage to create the virtual machine')
        disk_size = DiskInfo.default.size_in_mb

        if disk_options['size']
          disk_size = disk_options['size']
        elsif disk_info && !raw_instance_storage?
          disk_size = disk_info.size_in_mb
        end

        volume_properties = VolumeProperties.new(
          size: disk_size,
          type: disk_options['type'],
          iops: disk_options['iops'],
        )

        volume_properties.validate!
        result = volume_properties.disk_mapping
      end

      result[:bosh_type] = 'ephemeral'
      result
    end

    def first_raw_ephemeral_device
      case @virtualization_type
        when :hvm
          '/dev/xvdba'
        when :paravirtual
          '/dev/sdc'
        else
          raise Bosh::Clouds::CloudError, "unknown virtualization type #{@virtualization_type}"
      end
    end

    def raw_instance_storage?
      @resource_pool.fetch('raw_instance_storage', false)
    end

    def raw_instance_mappings(num_of_devices)
      next_device = first_raw_ephemeral_device

      num_of_devices.times.map do |index|
        result = {
          virtual_name: "ephemeral#{index}",
          device_name: next_device,
          bosh_type: "raw_ephemeral",
        }
        next_device = next_device.next
        result
      end
    end

    def root_disk_mapping
      root_disk_size_in_mb = @resource_pool['root_disk']['size']
      root_disk_type = @resource_pool['root_disk'].fetch('type', 'standard')
      root_disk_iops = @resource_pool['root_disk']['iops']
      root_disk_volume_properties = VolumeProperties.new(
        size: root_disk_size_in_mb,
        type: root_disk_type,
        iops: root_disk_iops
      )
      root_disk_volume_properties.validate!

      root_device = {
        :volume_size => (root_disk_size_in_mb / 1024.0).ceil,
        :volume_type => root_disk_type,
        :delete_on_termination => true,
      }

      if root_disk_type == 'io1' && root_disk_iops > 0
        root_device[:iops] = root_disk_iops
      end

      if @virtualization_type == :hvm
        {
          device_name: "/dev/xvda",
          ebs: root_device
        }
      else
        {
          device_name: "/dev/sda",
          ebs: root_device
        }
      end
    end

    class DiskInfo
      INSTANCE_TYPE_DISK_MAPPING = {
        # previous generation
        'm1.small' => [160, 1],
        'm1.medium' => [410, 1],
        'm1.large' => [420, 2],
        'm1.xlarge' => [420, 4],

        'c1.medium' => [350, 1],
        'c1.xlarge' => [420, 4],

        'cc2.8xlarge' => [840, 4],

        'cg1.4xlarge' => [840, 2],

        'm2.xlarge' => [420, 1],
        'm2.2xlarge' => [850, 1],
        'm2.4xlarge' => [840, 2],

        'cr1.8xlarge' => [120, 2],

        'hi1.4xlarge' => [1024, 2],

        'hs1.8xlarge' => [2000, 24],

        # current generation
        'm3.medium' => [4, 1],
        'm3.large' => [32, 1],
        'm3.xlarge' => [40, 2],
        'm3.2xlarge' => [80, 2],

        'c3.large' => [16, 2],
        'c3.xlarge' => [40, 2],
        'c3.2xlarge' => [80, 2],
        'c3.4xlarge' => [160, 2],
        'c3.8xlarge' => [320, 2],

        'r3.large' => [32, 1],
        'r3.xlarge' => [80, 1],
        'r3.2xlarge' => [160, 1],
        'r3.4xlarge' => [320, 1],
        'r3.8xlarge' => [320, 2],

        'g2.2xlarge' => [60, 1],
        'g2.8xlarge' => [120, 2],

        'i2.xlarge' => [800, 1],
        'i2.2xlarge' => [800, 2],
        'i2.4xlarge' => [800, 4],
        'i2.8xlarge' => [800, 8],

        'd2.xlarge' => [2000, 3],
        'd2.2xlarge' => [2000, 6],
        'd2.4xlarge' => [2000, 12],
        'd2.8xlarge' => [2000, 2]
      }

      attr_reader :size, :count

      def self.default
        self.new(10, 1)
      end

      def self.for(instance_type)
        values = INSTANCE_TYPE_DISK_MAPPING[instance_type]
        DiskInfo.new(*values) if values
      end

      def initialize(size, count)
        @size = size
        @count = count
      end

      def size_in_mb
        @size * 1024
      end
    end
  end
end
