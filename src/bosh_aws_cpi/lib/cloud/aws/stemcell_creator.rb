module Bosh::AwsCloud
  class StemcellCreator
    include Helpers

    # EBS direct API block size. StartSnapshot reports the authoritative value
    # per snapshot; this is only a fallback if the response omits it.
    EBS_DIRECT_BLOCK_SIZE = 524288 # 512 KiB
    # PutSnapshotBlock is capped at 1,000 req/s per snapshot; keep concurrency
    # comfortably under that so a single stemcell import stays within the cap.
    EBS_DIRECT_PUT_CONCURRENCY = 16
    # StartSnapshot moves the snapshot to `error` if it is not completed within
    # this many minutes.
    EBS_DIRECT_SNAPSHOT_TIMEOUT_MINUTES = 60

    attr_reader :resource
    attr_reader :image_path

    def initialize(resource, stemcell_props)
      @resource = resource
      @stemcell_props = stemcell_props
      @creation_tags = nil
    end

    # @param image_path [String] local path to the stemcell .tgz image
    # @param encrypted [Boolean] whether the snapshot must be encrypted
    # @param kms_key_arn [String, nil] optional KMS key; when nil and encrypted
    #   is true, AWS uses the account default EBS key
    # @param tags [Hash, nil] optional string-key tag hash
    # @return [Stemcell]
    def create(image_path, encrypted: false, kms_key_arn: nil, tags: nil)
      @image_path = image_path
      @creation_tags = TagManager.tags_hash(tags)

      Dir.mktmpdir('bosh-stemcell-ebs') do |dir|
        root_img = File.join(dir, 'root.img')
        extract_root_image(image_path, root_img)

        snapshot_id = write_snapshot_via_ebs_direct(root_img, encrypted, kms_key_arn)
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
      unless $?.success?
        raise Bosh::Clouds::CloudError, "Unable to extract stemcell root image from #{image_path} (tar exit #{$?.exitstatus})"
      end
    rescue SystemCallError => e
      raise Bosh::Clouds::CloudError, "Unable to extract stemcell root image: #{e.message}"
    end

    def write_snapshot_via_ebs_direct(root_img, encrypted, kms_key_arn)
      volume_size_gib = bytes_to_gib(File.size(root_img))
      has_kms_key = !(kms_key_arn.nil? || kms_key_arn.to_s.empty?)

      start_params = {
        volume_size: volume_size_gib,
        client_token: SecureRandom.uuid,
        timeout: EBS_DIRECT_SNAPSHOT_TIMEOUT_MINUTES,
      }
      if encrypted || has_kms_key
        start_params[:encrypted] = true
        start_params[:kms_key_arn] = kms_key_arn if has_kms_key
      end

      logger.info("starting EBS direct snapshot (#{volume_size_gib} GiB) for stemcell import")
      started = ebs_client.start_snapshot(start_params)
      snapshot_id = started.snapshot_id
      block_size = started.block_size || EBS_DIRECT_BLOCK_SIZE

      changed_blocks_count = put_snapshot_blocks(snapshot_id, root_img, block_size)

      logger.info("completing EBS direct snapshot '#{snapshot_id}' (#{changed_blocks_count} blocks written)")
      ebs_client.complete_snapshot(
        snapshot_id: snapshot_id,
        changed_blocks_count: changed_blocks_count,
      )

      wait_for_snapshot_completed(snapshot_id)
      snapshot_id
    rescue Aws::Errors::ServiceError => e
      raise Bosh::Clouds::CloudError, "EBS direct snapshot creation failed: #{e.message}"
    end

    # All-zero blocks are skipped: EBS reads unwritten blocks back as zero, so a
    # sparse stemcell disk only pays for the blocks that actually hold data.
    # Returns the number of blocks written (needed by CompleteSnapshot).
    def put_snapshot_blocks(snapshot_id, root_img, block_size)
      zero_block = "\0".b * block_size
      queue = Queue.new
      written = 0
      written_mutex = Mutex.new
      error = nil
      error_mutex = Mutex.new

      File.open(root_img, 'rb') do |f|
        index = 0
        while (chunk = f.read(block_size))
          chunk = chunk.ljust(block_size, "\0".b) if chunk.bytesize < block_size
          queue << [index, chunk] unless chunk == zero_block
          index += 1
        end
      end

      total = queue.size
      queue.close

      workers = Array.new([EBS_DIRECT_PUT_CONCURRENCY, [total, 1].max].min) do
        Thread.new do
          while (item = queue.pop)
            break if error_mutex.synchronize { !error.nil? }

            block_index, data = item
            begin
              put_one_block(snapshot_id, block_index, data)
              written_mutex.synchronize { written += 1 }
            rescue StandardError => e
              error_mutex.synchronize { error ||= e }
            end
          end
        end
      end
      workers.each(&:join)

      raise error if error

      written
    end

    def put_one_block(snapshot_id, block_index, data)
      checksum = Base64.strict_encode64(Digest::SHA256.digest(data))
      attempts = 0
      begin
        ebs_client.put_snapshot_block(
          snapshot_id: snapshot_id,
          block_index: block_index,
          block_data: StringIO.new(data),
          data_length: data.bytesize,
          checksum: checksum,
          checksum_algorithm: 'SHA256',
        )
      rescue Aws::Errors::ServiceError => e
        attempts += 1
        raise if attempts > 3

        logger.warn("retrying PutSnapshotBlock ##{block_index} on '#{snapshot_id}': #{e.message}")
        sleep(1)
        retry
      end
    end

    def wait_for_snapshot_completed(snapshot_id)
      snapshot = resource.snapshot(snapshot_id)
      ResourceWait.for_snapshot(snapshot: snapshot, state: 'completed')
    rescue Bosh::Common::RetryCountExceeded, Bosh::Clouds::CloudError => e
      raise Bosh::Clouds::CloudError, "Timed out waiting for EBS direct snapshot '#{snapshot_id}' to complete: #{e.message}"
    end

    def bytes_to_gib(bytes)
      gib = 1024 * 1024 * 1024
      [(bytes + gib - 1) / gib, 1].max
    end

    def tag_snapshot(snapshot_id)
      return if @creation_tags.nil? || @creation_tags.empty?

      snapshot = resource.snapshot(snapshot_id)
      TagManager.create_tags(snapshot, @creation_tags)
    rescue Aws::Errors::ServiceError => e
      # The snapshot already exists; a tag failure must not discard it.
      logger.error("could not tag snapshot #{snapshot_id}: #{e.message}")
    end

    # Reuses the EC2 client's resolved credentials and region so writes
    # authenticate as the configured CPI identity rather than the ambient
    # default credential chain.
    def ebs_client
      @ebs_client ||= begin
        ec2_config = resource.client.config
        params = { region: ec2_config.region }
        params[:credentials] = ec2_config.credentials if ec2_config.credentials
        Aws::EBS::Client.new(params)
      end
    end

    def register_image_from_snapshot(snapshot_id)
      # the top-level ec2 class' ImageCollection.create does not support the full set of params
      params = image_params(snapshot_id)
      image = resource.images(filters: [{name: 'image-id', values: [resource.client.register_image(params).image_id]}]).first
      ResourceWait.for_image(image: image, state: 'available')

      Stemcell.new(resource, image)
    end

    def image_params(snapshot_id)
      params = begin
        if @stemcell_props.paravirtual?
          aki = @stemcell_props.kernel_id || AKIPicker.new(resource).pick(@stemcell_props.architecture, @stemcell_props.root_device_name)
          {
            :kernel_id => aki,
            :root_device_name => @stemcell_props.root_device_name,
            :block_device_mappings => [
              {
                :device_name => '/dev/sda',
                :ebs => {
                  :snapshot_id => snapshot_id,
                },
              },
            ],
          }
        else
          {
            :virtualization_type => @stemcell_props.virtualization_type,
            :root_device_name => '/dev/xvda',
            :sriov_net_support => 'simple',
            :ena_support => true,
            :boot_mode => @stemcell_props.boot_mode,
            :block_device_mappings => [
              {
                :device_name => '/dev/xvda',
                :ebs => {
                  :snapshot_id => snapshot_id,
                },
              },
            ],
          }
        end
      end

      if @stemcell_props.old?
        params[:description] = @stemcell_props.formatted_name
      end

      params.merge!(
        :name => "BOSH-#{SecureRandom.uuid}",
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
