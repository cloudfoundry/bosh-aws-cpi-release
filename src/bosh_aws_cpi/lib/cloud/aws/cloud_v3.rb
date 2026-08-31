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
    # Light stemcells resolve (and optionally re-encrypt) an existing AMI. Heavy
    # stemcells route through the shared #dispatch_create_stemcell on CloudV1,
    # which chooses between the classic EBS path and the ImportSnapshot path, so
    # V1 and V3 cannot diverge.
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
          # Route the heavy path through the shared dispatch. Tags are sourced
          # from the env argument (V3-specific) rather than props.tags.
          stemcell_id = dispatch_create_stemcell(image_path, props, tags)

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

    # V3 light-stemcell handling, separate from CloudV1's shared dispatch
    # because V3 additionally applies env tags at resource creation.
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
