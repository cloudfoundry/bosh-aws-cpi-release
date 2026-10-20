module Bosh::AwsCloud
  # Orchestrates heavy-stemcell creation via the EBS direct API path:
  #   1. Decompress the stemcell tarball and stream the raw root image out.
  #   2. Upload it as an EBS snapshot (delegated to EbsDirectUploader).
  #   3. Register and return an AMI.
  class StemcellCreator
    include Helpers
    include StemcellImageParams

    BYTES_PER_GIB = 1024 * 1024 * 1024

    attr_reader :resource

    def initialize(resource, stemcell_props, ebs_client)
      @resource       = resource
      @stemcell_props = stemcell_props
      @ebs_client     = ebs_client
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

      # The snapshot size is fixed before any block is read, so it comes from
      # the stemcell's declared disk size rather than measuring the extracted
      # image. This lets us stream the root image straight from the tar pipe
      # into EbsDirectUploader without materializing a multi-GiB temp file
      # (which could exhaust TMPDIR / scratch space).
      volume_size_gib = compute_volume_size_gib
      snapshot_id = stream_root_image(image_path) do |image_io|
        uploader = EbsDirectUploader.new(@ebs_client, @resource)
        uploader.upload(
          image_io,
          volume_size_gib: volume_size_gib,
          encrypted:       encrypted,
          kms_key_arn:     kms_key_arn,
          tags:            @creation_tags,
        )
      end

      register_image_from_snapshot(snapshot_id)
    end

    private

    # Decompresses the stemcell tarball with `tar` and yields the stdout pipe of
    # the `root.img` member as an IO for the caller to stream. Uses IO.popen with
    # an argv array (no shell) so an image_path containing spaces or shell
    # metacharacters cannot be interpreted by a shell. The member is streamed
    # rather than extracted to disk or buffered in memory.
    def stream_root_image(image_path)
      result = nil
      IO.popen(['tar', '-xzf', image_path, '-O', 'root.img'], 'rb') do |tar_out|
        result = yield tar_out
      end
      tar_status = $?
      unless tar_status.success?
        raise Bosh::Clouds::CloudError, "Unable to extract stemcell root image from #{image_path} (tar exit #{tar_status.exitstatus})"
      end
      result
    rescue SystemCallError => e
      raise Bosh::Clouds::CloudError, "Unable to extract stemcell root image: #{e.message}"
    end

    # Size the snapshot from the configured disk property (default 2048 MiB) so
    # the registered AMI honours the stemcell contract. A well-formed stemcell's
    # root image always fits its declared disk; EbsDirectUploader guards against
    # an image that overruns this size.
    def compute_volume_size_gib
      bytes_to_gib(@stemcell_props.disk * 1024 * 1024)
    end

    def bytes_to_gib(bytes)
      [(bytes + BYTES_PER_GIB - 1) / BYTES_PER_GIB, 1].max
    end

    def register_image_from_snapshot(snapshot_id)
      # the top-level ec2 class' ImageCollection.create does not support the full set of params
      params = image_params(snapshot_id)
      image  = resource.images(filters: [{name: 'image-id', values: [resource.client.register_image(params).image_id]}]).first
      ResourceWait.for_image(image: image, state: 'available')

      Stemcell.new(resource, image)
    end

    def logger
      Bosh::Clouds::Config.logger
    end
  end
end
