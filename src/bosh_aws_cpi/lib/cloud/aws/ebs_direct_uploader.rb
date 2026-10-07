module Bosh::AwsCloud
  # Uploads a raw disk image to an EBS snapshot using the EBS direct APIs
  # (StartSnapshot / PutSnapshotBlock / CompleteSnapshot).
  #
  # Responsibilities:
  #   - Accept an injected Aws::EBS::Client.
  #   - Start a snapshot of the requested size with optional encryption and tags.
  #   - Upload all non-zero blocks concurrently from a local image file.
  #   - Complete the snapshot and wait for it to become available.
  #   - Delete an incomplete snapshot if an error occurs after start_snapshot.
  #
  # Callers are responsible for registering the AMI.
  class EbsDirectUploader
    include Helpers

    # PutSnapshotBlock is capped at 1,000 req/s per snapshot; keep concurrency
    # comfortably under that so a single stemcell import stays within the cap.
    PUT_CONCURRENCY = 16
    # StartSnapshot moves the snapshot to `error` if not completed within this
    # many minutes.
    SNAPSHOT_TIMEOUT_MINUTES = 60
    # Fallback block size if StartSnapshot omits it in the response.
    DEFAULT_BLOCK_SIZE = 524288 # 512 KiB

    def initialize(ebs_client, ec2_resource)
      @ebs_client   = ebs_client
      @ec2_resource = ec2_resource
    end

    # Uploads the raw image at +image_path+ into a new EBS snapshot.
    #
    # @param image_path [String] path to an uncompressed raw disk image
    # @param volume_size_gib [Integer] snapshot volume size in GiB
    # @param encrypted [Boolean] whether the snapshot should be encrypted
    # @param kms_key_arn [String, nil] KMS key ARN; nil uses the account default
    # @param tags [Hash, nil] tags to apply at snapshot creation time
    # @return [String] the completed snapshot ID
    def upload(image_path, volume_size_gib:, encrypted: false, kms_key_arn: nil, tags: nil)
      snapshot_id = nil
      snapshot_id = start_snapshot(volume_size_gib, encrypted, kms_key_arn, tags)
      block_size  = @started_block_size || DEFAULT_BLOCK_SIZE

      blocks_written = upload_blocks(snapshot_id, image_path, block_size)

      logger.info("completing EBS direct snapshot '#{snapshot_id}' (#{blocks_written} blocks written)")
      @ebs_client.complete_snapshot(
        snapshot_id:          snapshot_id,
        changed_blocks_count: blocks_written,
      )

      wait_for_snapshot_completed(snapshot_id)
      snapshot_id
    rescue Aws::EC2::Errors::AccessDenied, Aws::EC2::Errors::UnauthorizedOperation,
           Aws::EBS::Errors::AccessDeniedException => e
      raise
    rescue => e
      if snapshot_id
        begin
          @ec2_resource.client.delete_snapshot(snapshot_id: snapshot_id)
          logger.info("deleted incomplete snapshot '#{snapshot_id}' after upload failure")
        rescue => delete_err
          logger.warn("could not delete incomplete snapshot '#{snapshot_id}': #{delete_err.message}")
        end
      end
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
        snap_specs = TagManager.tag_specifications_for_resources(tags, ['snapshot'])
        params[:tag_specifications] = snap_specs unless snap_specs.empty?
      end

      logger.info("starting EBS direct snapshot (#{volume_size_gib} GiB) for stemcell import")
      response = @ebs_client.start_snapshot(params)
      @started_block_size = response.block_size
      response.snapshot_id
    end

    # Reads +image_path+ in +block_size+ chunks and uploads every non-zero block
    # concurrently. All-zero blocks are skipped: EBS returns zero for unwritten
    # blocks, so a sparse image only pays for the blocks that hold actual data.
    #
    # A Mutex+ConditionVariable semaphore bounds in-flight blocks to PUT_CONCURRENCY
    # so the producer pauses when all workers are busy. Unlike SizedQueue, the CV
    # signal fires even when a worker dies with an exception, preventing deadlock.
    def upload_blocks(snapshot_id, image_path, block_size)
      zero_block = "\0".b * block_size

      written       = 0
      written_mutex = Mutex.new

      in_flight     = 0
      sem_mutex     = Mutex.new
      sem_cv        = ConditionVariable.new

      pool = Bosh::ThreadPool.new(max_threads: PUT_CONCURRENCY, logger: logger)

      File.open(image_path, 'rb') do |f|
        index = 0
        while (chunk = f.read(block_size))
          chunk = chunk.ljust(block_size, "\0".b) if chunk.bytesize < block_size
          unless chunk == zero_block
            sem_mutex.synchronize { sem_cv.wait(sem_mutex) while in_flight >= PUT_CONCURRENCY }
            sem_mutex.synchronize { in_flight += 1 }
            captured_index = index
            captured_chunk = chunk
            pool.process do
              begin
                put_block(snapshot_id, captured_index, captured_chunk)
                written_mutex.synchronize { written += 1 }
              ensure
                sem_mutex.synchronize { in_flight -= 1; sem_cv.signal }
              end
            end
          end
          index += 1
        end
      end

      pool.wait
      written
    end

    def put_block(snapshot_id, block_index, data)
      checksum = Base64.strict_encode64(Digest::SHA256.digest(data))
      @ebs_client.put_snapshot_block(
        snapshot_id:        snapshot_id,
        block_index:        block_index,
        block_data:         -> { StringIO.new(data) },
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
