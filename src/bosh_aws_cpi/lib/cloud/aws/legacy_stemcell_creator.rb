module Bosh::AwsCloud
  # Legacy heavy-stemcell creator: attaches an EBS volume to the current EC2
  # instance, copies the root image via the stemcell-copy script, snapshots
  # the volume, and registers an AMI.
  #
  # Requires the CPI to run on an EC2 instance. Kept as a fallback while
  # operators migrate IAM policies to support EbsDirectUploader. Remove once
  # the EBS direct path is fully rolled out.
  class LegacyStemcellCreator
    include Bosh::Exec
    include Helpers
    include StemcellImageParams

    attr_reader :resource
    attr_reader :volume, :device_path, :image_path

    def initialize(resource, stemcell_props)
      @resource      = resource
      @stemcell_props = stemcell_props
      @creation_tags = nil
    end

    def create(volume, device_path, image_path, tags = nil)
      @volume      = volume
      @device_path = device_path
      @image_path  = image_path
      @creation_tags = TagManager.tags_hash(tags)

      copy_root_image

      snapshot = volume.create_snapshot(
        tag_specifications: TagManager.tag_specifications_for_resources(@creation_tags, ['snapshot']),
      )
      ResourceWait.for_snapshot(snapshot: snapshot, state: 'completed')

      params = image_params(snapshot.id)
      image  = resource.images(filters: [{name: 'image-id', values: [resource.client.register_image(params).image_id]}]).first
      ResourceWait.for_image(image: image, state: 'available')

      Stemcell.new(resource, image)
    end

    private

    def copy_root_image
      stemcell_copy = find_in_path('stemcell-copy')

      if stemcell_copy
        logger.debug('copying stemcell using stemcell-copy script')
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

    def find_in_path(command, path = ENV['PATH'])
      path.split(':').each do |dir|
        stemcell_copy = File.join(dir, command)
        return stemcell_copy if File.exist?(stemcell_copy)
      end
      nil
    end

    def logger
      Bosh::Clouds::Config.logger
    end
  end
end
