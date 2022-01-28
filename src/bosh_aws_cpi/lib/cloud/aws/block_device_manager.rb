module Bosh::AwsCloud
  class BlockDeviceManager
    DEFAULT_INSTANCE_STORAGE_DISK_MAPPING = { device_name: '/dev/sdb', virtual_name: 'ephemeral0' }.freeze
    NVME_EBS_BY_ID_DEVICE_PATH_PREFIX = '/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_'

    # Newer, nitro-based instances use NVMe storage volumes.
    # https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-types.html#ec2-nitro-instances
    NVME_INSTANCE_FAMILIES = %w[a1 c5 c5a c5ad c5d c5n c6g c6gd c6gn d3 d3en g4 i3en inf1 m5 m5a m5ad m5d m5dn m5n m5zn m6g m6gd m6i p3dn p4 r5 r5a r5ad r5b r5d r5dn r5n r6g r6gd r6i t3 t3a t4g z1d].freeze

    def initialize(logger, stemcell, vm_cloud_props)
      @logger = logger
      @vm_cloud_props = vm_cloud_props
      @virtualization_type = stemcell.ami.virtualization_type
      @root_device_name = stemcell.ami.root_device_name
      @ami_block_device_names = stemcell.ami.block_device_mappings.map { |blk| blk.device_name }
    end

    def mappings_and_info
      info = build_info

      return mappings(info), agent_info(info)
    end

    def self.device_path(device_name, instance_type, volume_id)
      if BlockDeviceManager.requires_nvme_device(instance_type)
        NVME_EBS_BY_ID_DEVICE_PATH_PREFIX + volume_id.sub('-', '')
      else
        device_name
      end
    end

    def self.block_device_ready?(device_path)
      candidatePaths = [device_path]
      unless device_path.start_with?(NVME_EBS_BY_ID_DEVICE_PATH_PREFIX)
        xvd_name = device_path.gsub(/^\/dev\/sd/, '/dev/xvd')
        candidatePaths << xvd_name
      end

      Bosh::AwsCloud::CloudCore::DEVICE_POLL_TIMEOUT.times do
        candidatePaths.each do |path|
          if File.blockdev?(path)
            return path
          end
        end

        sleep(1)
      end

      cloud_error('Cannot find EBS volume on current instance')
    end

    def self.requires_nvme_device(instance_type)
      instance_type = instance_type.nil? ? 'unspecified' : instance_type
      instance_family = instance_type.split(".")[0]
      NVME_INSTANCE_FAMILIES.include?(instance_family)
    end

    private

    def mappings(info)
      instance_type = @vm_cloud_props.instance_type.nil? ? 'unspecified' : @vm_cloud_props.instance_type
      if instance_type =~ /^i3\./
        info = info.reject { |device| device[:bosh_type] == 'raw_ephemeral' }
      end

      info.map { |entry| entry.reject { |k| k == :bosh_type } }
    end

    def agent_info(info)
      info.group_by { |v| v[:bosh_type] }.map do |type, devices|
        {
          type => devices.map do |device|
            @logger.info("Mapping device #{device.inspect} to path: #{device[:device_name].inspect}")
            { 'path' => device[:device_name] }
          end
        }
      end.select do |elem|
        elem[nil].nil?
      end.inject({}) do |a, b|
        a.merge(b)
      end
    end

    def build_info
      instance_type = @vm_cloud_props.instance_type.nil? ? 'unspecified' : @vm_cloud_props.instance_type

      disk_info = DiskInfo.for(instance_type)
      if @vm_cloud_props.raw_instance_storage? && disk_info.nil?
        raise Bosh::Clouds::CloudError, "raw_instance_storage requested for instance type '#{instance_type}' that does not have instance storage"
      end

      block_devices = []
      ephemeral_disk = @vm_cloud_props.ephemeral_disk
      unless ephemeral_disk.use_root_disk
        block_devices << ephemeral_disk_mapping(instance_type, disk_info)

        if @vm_cloud_props.raw_instance_storage?
          block_devices += raw_instance_mappings(disk_info.count)
        end
      end

      if @vm_cloud_props.root_disk.specified?
        block_devices << user_specified_root_disk_mapping
      else
        block_devices << default_root_disk_mapping
      end

      block_devices
    end

    def ephemeral_disk_mapping(instance_type, disk_info)
      ephemeral_disk = @vm_cloud_props.ephemeral_disk

      if ephemeral_disk.use_instance_storage
        if @vm_cloud_props.raw_instance_storage?
          raise Bosh::Clouds::CloudError, 'ephemeral_disk.use_instance_storage and raw_instance_storage cannot both be true'
        end

        if ephemeral_disk.invalid_instance_storage_config?
          raise Bosh::Clouds::CloudError, 'use_instance_storage cannot be combined with additional ephemeral_disk properties'
        end

        if disk_info.nil?
          raise Bosh::Clouds::CloudError, "use_instance_storage requested for instance type '#{instance_type}' that does not have instance storage"
        end

        @logger.debug('Use instance storage to create the virtual machine')
        result = DEFAULT_INSTANCE_STORAGE_DISK_MAPPING.dup
      else
        @logger.debug('Use EBS storage to create the virtual machine')
        disk_size = DiskInfo.default.size_in_mb

        if ephemeral_disk.size
          disk_size = ephemeral_disk.size
        elsif disk_info && !@vm_cloud_props.raw_instance_storage?
          disk_size = disk_info.size_in_mb
        end

        result = VolumeProperties.new(
          size: disk_size,
          type: ephemeral_disk.type,
          iops: ephemeral_disk.iops,
          throughput: ephemeral_disk.throughput,
          encrypted: ephemeral_disk.encrypted,
          kms_key_arn: ephemeral_disk.kms_key_arn,
        ).ephemeral_disk_config
      end

      result[:bosh_type] = 'ephemeral'
      result
    end

    def first_raw_ephemeral_device
      instance_type = @vm_cloud_props.instance_type.nil? ? 'unspecified' : @vm_cloud_props.instance_type
      case @virtualization_type

        when 'hvm'
          if instance_type =~ /^i3\./
            '/dev/nvme0n1'
          else
            '/dev/xvdba'
          end
        when 'paravirtual'
          '/dev/sdc'
        else
          raise Bosh::Clouds::CloudError, "unknown virtualization type #{@virtualization_type}"
      end
    end

    def raw_instance_mappings(num_of_devices)
      next_device = first_raw_ephemeral_device

      num_of_devices.times.map do |index|
        result = {
          virtual_name: "ephemeral#{index}",
          device_name: next_device,
          bosh_type: 'raw_ephemeral',
        }
        next_device = next_raw_ephemeral_disk(next_device)
        result
      end
    end

    def user_specified_root_disk_mapping
      disk_properties = VolumeProperties.new(
        size: @vm_cloud_props.root_disk.size,
        type: @vm_cloud_props.root_disk.type,
        iops: @vm_cloud_props.root_disk.iops,
        throughput: @vm_cloud_props.root_disk.throughput,
        virtualization_type: @virtualization_type,
        root_device_name: root_device_name,
      )
      disk_properties.root_disk_config
    end

    def default_root_disk_mapping
      disk_properties = VolumeProperties.new(
        virtualization_type: @virtualization_type,
        root_device_name: root_device_name,
      )
      disk_properties.root_disk_config
    end

    def root_device_name
      if @root_device_name
        # covers two cases:
        # 1. root and block device match exactly
        # 2. root is a partition and block device is the entire device
        #    e.g. root == /dev/sda1 and block device == /dev/sda
        block_device_to_override = (@ami_block_device_names || {}).find do |name|
          @root_device_name == name
        end
        block_device_to_override ||= (@ami_block_device_names || {}).find do |name|
          @root_device_name.start_with?(name)
        end

        return block_device_to_override if block_device_to_override
      end

      # fallback
      if @virtualization_type == 'paravirtual'
        return '/dev/sda'
      else
        return '/dev/xvda'
      end
    end

    def next_raw_ephemeral_disk(current_disk)
      if current_disk =~ /^\/dev\/nvme/
        disk_id = /^\/dev\/nvme(\d+)n.*/.match(current_disk)[1]
        disk_id = disk_id.next
        "/dev/nvme#{disk_id}n1"
      else
        current_disk.next
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

        'i3.large' => [475, 1],
        'i3.xlarge' => [950, 1],
        'i3.2xlarge' => [1900, 1],
        'i3.4xlarge' => [1900, 2],
        'i3.8xlarge' => [1900, 4],
        'i3.16xlarge' => [1900, 8],

        'd2.xlarge' => [2000, 3],
        'd2.2xlarge' => [2000, 6],
        'd2.4xlarge' => [2000, 12],
        'd2.8xlarge' => [2000, 24],

        'x1.16xlarge' => [1920, 1],
        'x1.32xlarge' => [1920, 2],
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
