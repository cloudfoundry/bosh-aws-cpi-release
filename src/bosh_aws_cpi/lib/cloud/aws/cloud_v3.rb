require "cloud/aws/stemcell_finder"
require "uri"
require "cloud_v2"

module Bosh::AwsCloud
  class CloudV3 < Bosh::AwsCloud::CloudV2

    # Current CPI API version supported by this CPI
    API_VERSION = 3

    ##
    # Creates a new EC2 AMI using stemcell image.
    # This method can only be run on an EC2 instance, as image creation
    # involves creating and mounting new EBS volume as local block device.
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
        tags = nil

        if !env.nil?
          tags = env["tags"] || nil
        end

        if props.is_light?
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
            copy_image_result = @ec2_client.copy_image(
              source_region: @config.aws.region,
              source_image_id: props.region_ami,
              name: "Copied from SourceAMI #{props.region_ami}",
              encrypted: props.encrypted,
              kms_key_id: props.kms_key_arn,
            )

            encrypted_image_id = copy_image_result.image_id
            encrypted_image = @ec2_resource.image(encrypted_image_id)
            ResourceWait.for_image(image: encrypted_image, state: "available")

            if !tags.nil?
              TagManager.create_tags(encrypted_image, tags)
            end

            return encrypted_image_id.to_s
          end

          if !tags.nil?
            TagManager.create_tags(available_image, tags)
          end

          "#{available_image.id} light"
        else
          stemcell_id = create_ami_for_stemcell(image_path, props)

          if !tags.nil?
            created_ami = @ec2_resource.images(
              filters: [{
                          name: "image-id",
                          values: [stemcell_id],
                        }]
              ).first

            TagManager.create_tags(created_ami, tags)
          end
          logger.info("Tagged #{stemcell_id} with #{tags}.")
          stemcell_id
        end
      end
    end
  end
end
