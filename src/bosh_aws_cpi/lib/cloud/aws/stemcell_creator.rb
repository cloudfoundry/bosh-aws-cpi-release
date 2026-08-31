module Bosh::AwsCloud
  class StemcellCreator
    include Bosh::Exec
    include Helpers

    IMPORT_SNAPSHOT_POLL_TIMEOUT = 3600 # in seconds
    IMPORT_SNAPSHOT_POLL_INTERVAL = 15 # in seconds

    attr_reader :resource
    attr_reader :volume, :device_path, :image_path

    def initialize(resource, stemcell_props)
      @resource = resource
      @stemcell_props = stemcell_props
      @creation_tags = nil
    end

    # @param tags [Hash, nil] optional string-key tag hash (e.g. Director env tags) applied at snapshot and AMI registration
    def create(volume, device_path, image_path, tags = nil)
      @volume = volume
      @device_path = device_path
      @image_path = image_path
      @creation_tags = TagManager.tags_hash(tags)

      copy_root_image

      snapshot = volume.create_snapshot(
        tag_specifications: TagManager.tag_specifications_for_resources(@creation_tags, ['snapshot']),
      )
      ResourceWait.for_snapshot(snapshot: snapshot, state: 'completed')

      # the top-level ec2 class' ImageCollection.create does not support the full set of params
      register_image_from_snapshot(snapshot.id)
    end

    # Container-friendly alternative to #create that does not require the CPI
    # to run on an EC2 instance. Instead of attaching an EBS volume and dd-ing
    # root.img onto the block device, it uploads root.img to an S3 staging
    # bucket and uses the AWS ImportSnapshot API (VM Import/Export) to build
    # the snapshot server-side, then registers the AMI from that snapshot.
    #
    # @param image_path [String] local path to the stemcell .tgz image
    # @param s3_bucket [String] name of an S3 bucket the vmimport role can read
    # @param import_role_name [String, nil] optional VM Import/Export role name
    # @param encrypted [Boolean] whether the imported snapshot must be encrypted
    # @param kms_key_arn [String, nil] optional KMS key to encrypt the snapshot;
    #   when nil and encrypted is true, AWS uses the account default EBS key
    # @param tags [Hash, nil] optional string-key tag hash
    def create_via_import_snapshot(image_path, s3_bucket, import_role_name: nil, encrypted: false, kms_key_arn: nil, tags: nil)
      @image_path = image_path
      @creation_tags = TagManager.tags_hash(tags)

      s3_key = "bosh-stemcell-import/#{SecureRandom.uuid}/root.img"
      begin
        upload_root_image_to_s3(image_path, s3_bucket, s3_key)
        snapshot_id = import_snapshot(s3_bucket, s3_key, import_role_name, encrypted, kms_key_arn)
        tag_snapshot(snapshot_id)
        register_image_from_snapshot(snapshot_id)
      ensure
        delete_s3_object(s3_bucket, s3_key)
      end
    end

    private

    # Extracts root.img out of the stemcell .tgz and uploads it to S3 using a
    # multipart upload (Aws::S3::Object#upload_file), so the whole raw image is
    # streamed from disk in parts rather than buffered in memory or capped at
    # the 5 GB single-PUT limit. Returns nothing; raises CloudError on failure.
    def upload_root_image_to_s3(image_path, bucket, key)
      logger.info("uploading stemcell root image to s3://#{bucket}/#{key}")

      Dir.mktmpdir('bosh-stemcell-import') do |dir|
        root_img = File.join(dir, 'root.img')
        extract_root_image(image_path, root_img)

        obj = s3_resource.bucket(bucket).object(key)
        obj.upload_file(root_img)
      end
    rescue Aws::Errors::ServiceError => e
      raise Bosh::Clouds::CloudError, "Unable to upload stemcell root image to S3: #{e.message}"
    end

    # Streams `root.img` out of the stemcell tarball onto disk. Uses IO.popen
    # with an argv array (no shell), so an image_path containing spaces or shell
    # metacharacters cannot be interpreted by a shell, and the multi-GB member
    # is streamed rather than buffered in memory.
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

    def import_snapshot(bucket, key, import_role_name, encrypted, kms_key_arn)
      disk_container = {
        description: 'BOSH stemcell root image',
        format: 'RAW',
        url: "s3://#{bucket}/#{key}",
      }
      params = {
        description: 'BOSH stemcell import',
        disk_container: disk_container,
      }
      params[:role_name] = import_role_name if import_role_name

      has_kms_key = !(kms_key_arn.nil? || kms_key_arn.to_s.empty?)
      # Encrypt when either an explicit KMS key is given or the stemcell props
      # request encryption (which may rely on the account default EBS key).
      # Previously this only fired for an explicit ARN, silently producing an
      # unencrypted snapshot for encrypt-by-policy accounts with no ARN set.
      if encrypted || has_kms_key
        params[:encrypted] = true
        params[:kms_key_id] = kms_key_arn if has_kms_key
      end

      logger.info("starting ImportSnapshot from s3://#{bucket}/#{key}")
      import_task = resource.client.import_snapshot(params)
      task_id = import_task.import_task_id

      snapshot_id = wait_for_import_snapshot(task_id)
      logger.info("ImportSnapshot task '#{task_id}' produced snapshot '#{snapshot_id}'")
      snapshot_id
    rescue Aws::Errors::ServiceError => e
      raise Bosh::Clouds::CloudError, "ImportSnapshot failed: #{e.message}"
    end

    def wait_for_import_snapshot(task_id)
      deadline = Time.now + IMPORT_SNAPSHOT_POLL_TIMEOUT
      loop do
        begin
          resp = resource.client.describe_import_snapshot_tasks(import_task_ids: [task_id])
        rescue Aws::Errors::ServiceError => e
          # A transient throttle/5xx during the (up to 1h) poll should not abort
          # the whole import; log and retry until the deadline is reached.
          raise Bosh::Clouds::CloudError, "ImportSnapshot polling failed: #{e.message}" if Time.now > deadline

          logger.warn("transient error polling ImportSnapshot task '#{task_id}', will retry: #{e.message}")
          sleep(IMPORT_SNAPSHOT_POLL_INTERVAL)
          next
        end

        task = resp.import_snapshot_tasks.first
        detail = task&.snapshot_task_detail
        status = detail&.status

        case status
        when 'completed'
          return detail.snapshot_id
        when 'error', 'deleted', 'deleting'
          raise Bosh::Clouds::CloudError, "ImportSnapshot task '#{task_id}' failed: #{detail&.status_message}"
        end

        if Time.now > deadline
          raise Bosh::Clouds::CloudError, "Timed out waiting for ImportSnapshot task '#{task_id}' (last status: #{status})"
        end

        logger.debug("ImportSnapshot task '#{task_id}' status: #{status} (#{detail&.progress}%)")
        sleep(IMPORT_SNAPSHOT_POLL_INTERVAL)
      end
    end

    def tag_snapshot(snapshot_id)
      return if @creation_tags.nil? || @creation_tags.empty?

      snapshot = resource.snapshot(snapshot_id)
      TagManager.create_tags(snapshot, @creation_tags)
    rescue Aws::EC2::Errors::TagLimitExceeded => e
      logger.error("could not tag snapshot #{snapshot_id}: #{e.message}")
    end

    def delete_s3_object(bucket, key)
      s3_resource.bucket(bucket).object(key).delete
    rescue Aws::Errors::ServiceError => e
      logger.warn("could not delete staging object s3://#{bucket}/#{key}: #{e.message}")
    end

    # Builds an S3 resource that reuses the EC2 client's resolved credentials
    # and region, so the upload authenticates as the same identity the CPI is
    # configured with (static keys / instance-profile / AssumeRole) instead of
    # falling back to the ambient default credential chain. Memoized so a single
    # multipart upload and the cleanup delete share one client.
    def s3_resource
      @s3_resource ||= begin
        ec2_config = resource.client.config
        s3_params = { region: ec2_config.region }
        s3_params[:credentials] = ec2_config.credentials if ec2_config.credentials
        Aws::S3::Resource.new(s3_params)
      end
    end

    def register_image_from_snapshot(snapshot_id)
      params = image_params(snapshot_id)
      image = resource.images(filters: [{name: 'image-id', values: [resource.client.register_image(params).image_id]}]).first
      ResourceWait.for_image(image: image, state: 'available')

      Stemcell.new(resource, image)
    end

    # This method tries to execute the helper script stemcell-copy
    # as root using sudo, since it needs to write to the device_path.
    # If stemcell-copy isn't available, it falls back to writing directly
    # to the device, which is used in the micro bosh deployer.
    # The stemcell-copy script must be in the PATH of the user running
    # the director, and needs sudo privileges to execute without
    # password.
    #
    def copy_root_image
      stemcell_copy = find_in_path('stemcell-copy')

      if stemcell_copy
        logger.debug('copying stemcell using stemcell-copy script')
        # note that is is a potentially dangerous operation, but as the
        # stemcell-copy script sets PATH to a sane value this is safe
        command = "sudo -n #{stemcell_copy} #{image_path} #{device_path} 2>&1"
      else
        logger.info('falling back to using included copy stemcell')
        included_stemcell_copy = File.expand_path('../../../../bin/stemcell-copy', __FILE__)
        command = "sudo -n #{included_stemcell_copy} #{image_path} #{device_path} 2>&1"
      end

      result = sh(command)

      logger.debug("stemcell copy output:\n#{result.output}")
    rescue Bosh::Exec::Error => e
      raise Bosh::Clouds::CloudError, "Unable to copy stemcell root image: #{e.message}\nScript output:\n#{e.output}"
    end

    # checks if the stemcell-copy script can be found in
    # the current PATH
    def find_in_path(command, path=ENV['PATH'])
      path.split(':').each do |dir|
        stemcell_copy = File.join(dir, command)
        return stemcell_copy if File.exist?(stemcell_copy)
      end
      nil
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
