module Bosh::AwsCloud
  # Uploads a raw disk image to an EBS snapshot using the EBS direct APIs
  # (StartSnapshot / PutSnapshotBlock / CompleteSnapshot).
  class EbsDirectUploader
    include Helpers

    # PutSnapshotBlock is capped at 1,000 req/s per snapshot; keep concurrency
    # comfortably under that so a single stemcell import stays within the cap.
    PUT_CONCURRENCY = 16
    SNAPSHOT_TIMEOUT_MINUTES = 60
    # Bound the producer-consumer queue so the reader blocks when workers fall
    # behind; 2x concurrency keeps ~16 MiB of block data in flight at most.
    QUEUE_DEPTH = PUT_CONCURRENCY * 2
    DEFAULT_BLOCK_SIZE = 524288 # 512 KiB
    BYTES_PER_GIB = 1024 * 1024 * 1024

    def initialize(ebs_client, ec2_resource)
      @ebs_client   = ebs_client
      @ec2_resource = ec2_resource
    end

    # @param image_io [IO] readable stream of an uncompressed raw disk image
    # @param volume_size_gib [Integer] snapshot volume size in GiB
    # @param encrypted [Boolean] whether the snapshot should be encrypted
    # @param kms_key_arn [String, nil] KMS key ARN; nil uses the account default
    # @param tags [Hash, nil] tags to apply at snapshot creation time
    # @return [String] the completed snapshot ID
    def upload(image_io, volume_size_gib:, encrypted: false, kms_key_arn: nil, tags: nil)
      snapshot_id = nil
      snapshot_id = start_snapshot(volume_size_gib, encrypted, kms_key_arn, tags)
      block_size  = @started_block_size || DEFAULT_BLOCK_SIZE

      blocks_written = upload_blocks(snapshot_id, image_io, block_size, volume_size_gib)

      logger.info("completing EBS direct snapshot '#{snapshot_id}' (#{blocks_written} blocks written)")
      @ebs_client.complete_snapshot(
        snapshot_id:          snapshot_id,
        changed_blocks_count: blocks_written,
      )

      wait_for_snapshot_completed(snapshot_id)
      snapshot_id
    rescue => e
      if snapshot_id
        begin
          @ec2_resource.client.delete_snapshot(snapshot_id: snapshot_id)
          logger.info("deleted incomplete snapshot '#{snapshot_id}' after upload failure")
        rescue => delete_err
          logger.warn("could not delete incomplete snapshot '#{snapshot_id}': #{delete_err.message}")
        end
      end
      # Re-raise permission errors unwrapped so callers can detect and fall back
      raise e if e.is_a?(Aws::EC2::Errors::AccessDenied) ||
                 e.is_a?(Aws::EC2::Errors::UnauthorizedOperation) ||
                 e.is_a?(Aws::EBS::Errors::AccessDeniedException)
      raise e if e.is_a?(Bosh::Clouds::CloudError)
      raise Bosh::Clouds::CloudError, "EBS direct snapshot creation failed: #{e.message}"
    end

    private

    def start_snapshot(volume_size_gib, encrypted, kms_key_arn, tags)
      params = {
        volume_size:  volume_size_gib,
        client_token: SecureRandom.uuid,
        timeout:      SNAPSHOT_TIMEOUT_MINUTES,
      }
      if encrypted
        params[:encrypted]   = true
        params[:kms_key_arn] = kms_key_arn if !kms_key_arn.to_s.empty?
      end

      unless tags.nil? || tags.empty?
        # EBS StartSnapshot accepts `tags` directly (not `tag_specifications` as in the EC2 API).
        formatted = TagManager.format_tags(tags)
        params[:tags] = formatted unless formatted.empty?
      end

      logger.info("starting EBS direct snapshot (#{volume_size_gib} GiB) for stemcell import")
      response = @ebs_client.start_snapshot(params)
      @started_block_size = response.block_size
      response.snapshot_id
    end

    # Skips all-zero blocks (EBS returns zero for unwritten blocks). Uses a SizedQueue producer-
    # consumer pattern to overlap I/O and upload without buffering the full image in memory.
    # Bosh::ThreadPool is intentionally avoided: its fail-fast behaviour deadlocks the producer
    # when workers stop draining the queue after an error.
    def upload_blocks(snapshot_id, image_io, block_size, volume_size_gib)
      zero_block    = "\0".b * block_size
      max_blocks    = (volume_size_gib * BYTES_PER_GIB) / block_size
      queue         = SizedQueue.new(QUEUE_DEPTH)
      written       = 0
      written_mutex = Mutex.new
      error         = nil
      error_mutex   = Mutex.new

      workers = Array.new(PUT_CONCURRENCY) do
        Thread.new do
          while (item = queue.pop) != :done
            next if error_mutex.synchronize { !error.nil? }

            block_index, data = item
            begin
              put_block(snapshot_id, block_index, data)
              written_mutex.synchronize { written += 1 }
            rescue StandardError => e
              error_mutex.synchronize { error ||= e }
            end
          end
        end
      end

      begin
        index = 0
        while (chunk = image_io.read(block_size))
          break if error_mutex.synchronize { !error.nil? }

          if index >= max_blocks
            raise Bosh::Clouds::CloudError,
                  "stemcell image exceeds declared volume size of #{volume_size_gib} GiB"
          end

          chunk = chunk.ljust(block_size, "\0".b) if chunk.bytesize < block_size
          queue << [index, chunk] unless chunk == zero_block
          index += 1
        end
      ensure
        PUT_CONCURRENCY.times { queue << :done }
        workers.each(&:join)
      end

      raise error if error

      written
    end

    def put_block(snapshot_id, block_index, data)
      checksum = Base64.strict_encode64(Digest::SHA256.digest(data))
      # Build a fresh StringIO per call so SDK retries don't send a zero-length body.
      @ebs_client.put_snapshot_block(
        snapshot_id:        snapshot_id,
        block_index:        block_index,
        block_data:         StringIO.new(data),
        data_length:        data.bytesize,
        checksum:           checksum,
        checksum_algorithm: 'SHA256',
      )
    end

    def wait_for_snapshot_completed(snapshot_id)
      snapshot = @ec2_resource.snapshot(snapshot_id)
      ResourceWait.for_snapshot(snapshot: snapshot, state: 'completed')
    rescue Bosh::Clouds::CloudError => e
      snapshot.reload rescue nil
      reason = snapshot.state_message rescue nil
      msg = reason.to_s.empty? ? e.message : "#{e.message} (#{reason})"
      raise Bosh::Clouds::CloudError, msg
    rescue Bosh::Common::RetryCountExceeded => e
      raise Bosh::Clouds::CloudError, "Timed out waiting for EBS direct snapshot '#{snapshot_id}' to complete: #{e.message}"
    end

    def logger
      Bosh::Clouds::Config.logger
    end
  end
end
