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

    # Uses IO.popen with an argv array (not a shell string) so image_path with spaces or
    # metacharacters is safe. Streams root.img directly without writing a temp file.
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
