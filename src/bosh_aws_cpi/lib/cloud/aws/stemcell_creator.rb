module Bosh::AwsCloud
  # Orchestrates heavy-stemcell creation via the EBS direct API path:
  #   1. Extract the raw root image from the stemcell tarball.
  #   2. Upload it as an EBS snapshot (delegated to EbsDirectUploader).
  #   3. Tag the snapshot.
  #   4. Register and return an AMI.
  class StemcellCreator
    include Helpers

    BYTES_PER_GIB = 1024 * 1024 * 1024

    attr_reader :resource

    def initialize(resource, stemcell_props, aws_config)
      @resource       = resource
      @stemcell_props = stemcell_props
      @aws_config     = aws_config
      @creation_tags  = nil
    end

    # @param image_path [String] local path to the stemcell .tgz image
    # @param encrypted [Boolean] whether the snapshot must be encrypted
    # @param kms_key_arn [String, nil] optional KMS key; when nil and encrypted
    #   is true, AWS uses the account default EBS key
    # @param tags [Hash, nil] optional string-key tag hash
    # @return [Stemcell]
    def create(image_path, encrypted: false, kms_key_arn: nil, tags: nil)
      @creation_tags = TagManager.tags_hash(tags)

      Dir.mktmpdir('bosh-stemcell-ebs') do |dir|
        root_img = File.join(dir, 'root.img')
        extract_root_image(image_path, root_img)

        volume_size_gib = compute_volume_size_gib(root_img)
        uploader    = EbsDirectUploader.new(@aws_config, @resource)
        snapshot_id = uploader.upload(
          root_img,
          volume_size_gib: volume_size_gib,
          encrypted:       encrypted,
          kms_key_arn:     kms_key_arn,
        )

        tag_snapshot(snapshot_id)
        register_image_from_snapshot(snapshot_id)
      end
    end

    private

    # Uses IO.popen with an argv array (no shell) so an image_path containing
    # spaces or shell metacharacters cannot be interpreted by a shell, and the
    # multi-GB member is streamed rather than buffered in memory.
    def extract_root_image(image_path, dest_path)
      File.open(dest_path, 'wb') do |dest|
        IO.popen(['tar', '-xzf', image_path, '-O', 'root.img'], 'rb') do |tar_out|
          IO.copy_stream(tar_out, dest)
        end
      end
      tar_status = $?
      unless tar_status.success?
        raise Bosh::Clouds::CloudError, "Unable to extract stemcell root image from #{image_path} (tar exit #{tar_status.exitstatus})"
      end
    rescue SystemCallError => e
      raise Bosh::Clouds::CloudError, "Unable to extract stemcell root image: #{e.message}"
    end

    # Use the larger of the raw image size and the configured disk property
    # (default 2048 MiB) so the registered AMI honours the stemcell contract.
    def compute_volume_size_gib(root_img)
      image_gib = bytes_to_gib(File.size(root_img))
      disk_gib  = bytes_to_gib(@stemcell_props.disk * 1024 * 1024)
      [image_gib, disk_gib].max
    end

    def bytes_to_gib(bytes)
      [(bytes + BYTES_PER_GIB - 1) / BYTES_PER_GIB, 1].max
    end

    def tag_snapshot(snapshot_id)
      return if @creation_tags.nil? || @creation_tags.empty?

      snapshot = resource.snapshot(snapshot_id)
      TagManager.create_tags(snapshot, @creation_tags)
    rescue Aws::Errors::ServiceError => e
      # The snapshot already exists; a tag failure must not discard it.
      logger.error("could not tag snapshot #{snapshot_id}: #{e.message}")
    end

    def register_image_from_snapshot(snapshot_id)
      # the top-level ec2 class' ImageCollection.create does not support the full set of params
      params = image_params(snapshot_id)
      image  = resource.images(filters: [{name: 'image-id', values: [resource.client.register_image(params).image_id]}]).first
      ResourceWait.for_image(image: image, state: 'available')

      Stemcell.new(resource, image)
    end

    def image_params(snapshot_id)
      params = begin
        if @stemcell_props.paravirtual?
          aki = @stemcell_props.kernel_id || AKIPicker.new(resource).pick(@stemcell_props.architecture, @stemcell_props.root_device_name)
          {
            :kernel_id          => aki,
            :root_device_name   => @stemcell_props.root_device_name,
            :block_device_mappings => [
              {
                :device_name => '/dev/sda',
                :ebs         => { :snapshot_id => snapshot_id },
              },
            ],
          }
        else
          {
            :virtualization_type => @stemcell_props.virtualization_type,
            :root_device_name    => '/dev/xvda',
            :sriov_net_support   => 'simple',
            :ena_support         => true,
            :boot_mode           => @stemcell_props.boot_mode,
            :block_device_mappings => [
              {
                :device_name => '/dev/xvda',
                :ebs         => { :snapshot_id => snapshot_id },
              },
            ],
          }
        end
      end

      params[:description] = @stemcell_props.formatted_name if @stemcell_props.old?

      params.merge!(
        :name         => "BOSH-#{SecureRandom.uuid}",
        :architecture => @stemcell_props.architecture,
      )

      params[:block_device_mappings].push(BlockDeviceManager::DEFAULT_INSTANCE_STORAGE_DISK_MAPPING)

      image_tag_hash = @creation_tags.nil? ? {} : @creation_tags
      image_tag_hash['Name'] = params[:description] if params[:description]
      img_specs = TagManager.tag_specifications_for_resources(image_tag_hash, ['image'])
      params[:tag_specifications] = img_specs unless img_specs.empty?

      params
    end

    def logger
      Bosh::Clouds::Config.logger
    end
  end
end
