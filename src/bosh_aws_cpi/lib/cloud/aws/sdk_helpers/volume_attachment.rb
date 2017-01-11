module Bosh::AwsCloud::SdkHelpers

  # Attachments are no longer a first-class citizen in AWS SDK v2
  # This class is adapted from the original v1 Attachment object:
  #   https://github.com/aws/aws-sdk-ruby/blob/74ba5eb8eb0c083ba03d3d3c01ec04fa1e51f421/lib/aws/ec2/attachment.rb
  class VolumeAttachment

    attr_reader :volume
    attr_reader :instance
    attr_reader :device

    def initialize(attachment, resource_client)
      @volume = resource_client.volume(attachment.volume_id)
      @instance = resource_client.instance(attachment.instance_id)
      @device = attachment.device
    end

    def state
      target_attachment = @volume.attachments.find { |a| a.device == @device && a.instance_id == @instance.id }
      if target_attachment.nil?
        raise Aws::EC2::Errors::InvalidVolumeNotFound.new(nil, "Unable to find disk attachment '#{@device}' with volume '#{@volume.id}' and instance '#{@instance.id}'")
      end

      target_attachment.state
    end

    def reload
      @volume.reload
    end
  end
end