require "cloud/aws/stemcell_finder"
require "uri"
require "cloud_v2"

module Bosh::AwsCloud
  class CloudV3 < Bosh::AwsCloud::CloudV2

    # Current CPI API version supported by this CPI
    API_VERSION = 3

    ##
    # Creates a new EC2 AMI using stemcell image.
    #
    # For light stemcells this resolves (and optionally re-encrypts) an existing
    # AMI. For full (heavy) stemcells the choice between the classic
    # EBS/current_vm_id path and the container-friendly ImportSnapshot path is
    # made by the shared #dispatch_create_stemcell helper on CloudV1, so V1 and
    # V3 can no longer diverge (this override previously omitted the
    # ImportSnapshot branch entirely, forcing heavy stemcells onto the
    # off-EC2-incompatible classic path whenever bosh negotiated api_version 3).
    #
    # @param [String] image_path local filesystem path to a stemcell image
    # @param [Hash] cloud_properties AWS-specific stemcell properties
    # @option cloud_properties [String] kernel_id
    #   AKI, auto-selected based on the architecture and root device, unless specified
    # @option cloud_properties [String] root_device_name
    #   block device path (e.g. /dev/sda1), provided by the stemcell manifest, unless specified
    # @option cloud_properties [String] architecture
    #   instruction set architecture (e.g. x86_64), provided by the stemcell manifest,
    #   unless specified
    # @option cloud_properties [String] disk (2048)
    #   root disk size
    # @param [Hash] env Environment tags
    # @option env [Hash] tags
    #   Key value pairs used for for tagging the resource.
    # @return [String] EC2 AMI name of the stemcell
    def create_stemcell(image_path, stemcell_properties, env = {})
      with_thread_name("create_stemcell(#{image_path}...)") do
        props = @props_factory.stemcell_props(stemcell_properties)
        tags = TagManager.tags_hash(env&.dig("tags"))

        if props.is_light?
          create_light_stemcell_v3(props, tags)
        else
          # Route the heavy path through the shared dispatch so the
          # ImportSnapshot opt-in is honored identically to CloudV1. Tags are
          # sourced from the env argument (V3-specific) rather than props.tags.
          stemcell_id = dispatch_create_stemcell(image_path, props, stemcell_properties, tags)

          if !tags.nil? && !tags.empty?
            logger.info("Created stemcell AMI #{stemcell_id} with env tags applied at resource creation: #{tags.keys.inspect}")
          else
            logger.info("Created stemcell AMI #{stemcell_id}.")
          end
          stemcell_id
        end
      end
    end

    private

    # V3 light-stemcell handling, kept separate from CloudV1's shared dispatch
    # because V3 additionally applies env tags at resource creation:
    # tag_specifications on the encrypted copy_image call and explicit
    # create_tags on the resolved image otherwise.
    def create_light_stemcell_v3(props, tags)
      # select the correct image for the configured ec2 client
      available_image = @ec2_resource.images(
        filters: [{
          name: "image-id",
          values: props.ami_ids,
        }],
        include_deprecated: true,
      ).first
      raise Bosh::Clouds::CloudError, "Stemcell does not contain an AMI in region #{@config.aws.region}" unless available_image

      if props.encrypted
        copy_opts = {
          source_region: @config.aws.region,
          source_image_id: props.region_ami,
          name: "Copied from SourceAMI #{props.region_ami}",
          encrypted: props.encrypted,
          kms_key_id: props.kms_key_arn,
        }
        img_specs = TagManager.tag_specifications_for_resources(tags, %w[image snapshot])
        copy_opts[:tag_specifications] = img_specs unless img_specs.empty?

        copy_image_result = @ec2_client.copy_image(**copy_opts)

        encrypted_image_id = copy_image_result.image_id
        encrypted_image = @ec2_resource.image(encrypted_image_id)
        ResourceWait.for_image(image: encrypted_image, state: "available")

        return encrypted_image_id.to_s
      end

      if !tags.nil?
        TagManager.create_tags(available_image, tags)
      end

      "#{available_image.id} light"
    end
  end
end
