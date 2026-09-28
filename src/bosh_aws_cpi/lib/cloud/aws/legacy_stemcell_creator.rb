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

    def image_params(snapshot_id)
      params = begin
        if @stemcell_props.paravirtual?
          aki = @stemcell_props.kernel_id || AKIPicker.new(resource).pick(@stemcell_props.architecture, @stemcell_props.root_device_name)
          {
            :kernel_id          => aki,
            :root_device_name   => @stemcell_props.root_device_name,
            :block_device_mappings => [
              {
                :device_name => '/dev/sda',
                :ebs         => { :snapshot_id => snapshot_id },
              },
            ],
          }
        else
          {
            :virtualization_type => @stemcell_props.virtualization_type,
            :root_device_name    => '/dev/xvda',
            :sriov_net_support   => 'simple',
            :ena_support         => true,
            :boot_mode           => @stemcell_props.boot_mode,
            :block_device_mappings => [
              {
                :device_name => '/dev/xvda',
                :ebs         => { :snapshot_id => snapshot_id },
              },
            ],
          }
        end
      end

      params[:description] = @stemcell_props.formatted_name if @stemcell_props.old?

      params.merge!(
        :name         => "BOSH-#{SecureRandom.uuid}",
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
