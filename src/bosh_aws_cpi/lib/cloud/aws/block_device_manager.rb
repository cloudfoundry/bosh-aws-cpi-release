
module Bosh::AwsCloud
  class BlockDeviceManager
    include Helpers

    attr_writer :resource_pool
    attr_writer :virtualization_type

    DEFAULT_VIRTUALIZATION_TYPE = :hvm

    class DiskInfo
      attr_reader :size, :count

      def initialize(size, count)
        @size = size
        @count = count
      end
    end

    InstanceStorageMap = {
      # previous generation
      'm1.small' => DiskInfo.new(160, 1),
      'm1.medium' => DiskInfo.new(410, 1),
      'm1.large' => DiskInfo.new(420, 2),
      'm1.xlarge' => DiskInfo.new(420, 4),

      'c1.medium' => DiskInfo.new(350, 1),
      'c1.xlarge' => DiskInfo.new(420, 4),

      'cc2.8xlarge' => DiskInfo.new(840, 4),

      'cg1.4xlarge' => DiskInfo.new(840, 2),

      'm2.xlarge' => DiskInfo.new(420, 1),
      'm2.2xlarge' => DiskInfo.new(850, 1),
      'm2.4xlarge' => DiskInfo.new(840, 2),

      'cr1.8xlarge' => DiskInfo.new(120, 2),

      'hi1.4xlarge' => DiskInfo.new(1024, 2),

      'hs1.8xlarge' => DiskInfo.new(2000, 24),

      # current generation
      'm3.medium' => DiskInfo.new(4, 1),
      'm3.large' => DiskInfo.new(32, 1),
      'm3.xlarge' => DiskInfo.new(40, 2),
      'm3.2xlarge' => DiskInfo.new(80, 2),

      'c3.large' => DiskInfo.new(16, 2),
      'c3.xlarge' => DiskInfo.new(40, 2),
      'c3.2xlarge' => DiskInfo.new(80, 2),
      'c3.4xlarge' => DiskInfo.new(160, 2),
      'c3.8xlarge' => DiskInfo.new(320, 2),

      'r3.large' => DiskInfo.new(32, 1),
      'r3.xlarge' => DiskInfo.new(80, 1),
      'r3.2xlarge' => DiskInfo.new(160, 1),
      'r3.4xlarge' => DiskInfo.new(320, 1),
      'r3.8xlarge' => DiskInfo.new(320, 2),

      'g2.2xlarge' => DiskInfo.new(60, 1),
      'g2.8xlarge' => DiskInfo.new(120, 2),

      'i2.xlarge' => DiskInfo.new(800, 1),
      'i2.2xlarge' => DiskInfo.new(800, 2),
      'i2.4xlarge' => DiskInfo.new(800, 4),
      'i2.8xlarge' => DiskInfo.new(800, 8),

      'd2.xlarge' => DiskInfo.new(2000, 3),
      'd2.2xlarge' => DiskInfo.new(2000, 6),
      'd2.4xlarge' => DiskInfo.new(2000, 12),
      'd2.8xlarge' => DiskInfo.new(2000, 24)
    }

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
      ephemeral_disk_options = @resource_pool.fetch("ephemeral_disk", {})

      requested_size = ephemeral_disk_options['size'] || 0
      actual_size = ephemeral_disk_options['size'] || 10 * 1024

      ephemeral_volume_properties = VolumeProperties.new(
        size: actual_size,
        type: ephemeral_disk_options['type'],
        iops: ephemeral_disk_options['iops'],
      )

      ephemeral_volume_properties.validate!

      instance_type = @resource_pool.fetch('instance_type', 'unspecified')
      raw_instance_storage = @resource_pool.fetch('raw_instance_storage', false)

      local_disk_info = InstanceStorageMap[instance_type]
      if raw_instance_storage && local_disk_info.nil?
        raise Bosh::Clouds::CloudError, "raw_instance_storage requested for instance type '#{instance_type}' that does not have instance storage"
      end

      if raw_instance_storage || local_disk_info.nil? || local_disk_info.size < (requested_size / 1024.0).ceil
        @logger.debug('Use EBS storage to create the virtual machine')
        block_device_mapping_param = InstancesCreatePresenter.new(ephemeral_volume_properties).present
      else
        @logger.debug('Use instance storage to create the virtual machine')
        block_device_mapping_param = default_ephemeral_disk_mapping
      end

      block_device_mapping_param[0][:bosh_type] = 'ephemeral'

      if raw_instance_storage
        next_device = first_raw_ephemeral_device
        for i in 0..local_disk_info.count - 1 do
          block_device_mapping_param << {
            virtual_name: "ephemeral#{i}",
            device_name: next_device,
            bosh_type: "raw_ephemeral",
          }
          next_device = next_device.next
        end
      end

      if (@resource_pool.has_key?('root_disk'))
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
          block_device_mapping_param << {
            device_name: "/dev/xvda",
            ebs: root_device
          }
        else
          block_device_mapping_param << {
            device_name: "/dev/sda",
            ebs: root_device
          }
        end
      end

      block_device_mapping_param
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
  end
end
