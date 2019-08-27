module Bosh::AwsCloud
  class StemcellCreator
    include Bosh::Exec
    include Helpers

    attr_reader :resource
    attr_reader :volume, :device_path, :image_path

    def initialize(resource, stemcell_props)
      @resource = resource
      @stemcell_props = stemcell_props
    end

    def create(volume, device_path, image_path)
      @volume = volume
      @device_path = device_path
      @image_path = image_path

      copy_root_image

      snapshot = volume.create_snapshot
      ResourceWait.for_snapshot(snapshot: snapshot, state: 'completed')

      # the top-level ec2 class' ImageCollection.create does not support the full set of params
      params = image_params(snapshot.id)
      image = AwsProvider.with_aws do
        resource.images(
          filters: [{
            name: 'image-id',
            values: [resource.client.register_image(params).image_id]
          }]
        ).first
      end
      ResourceWait.for_image(image: image, state: 'available')

      TagManager.tag(image, 'Name', params[:description]) if params[:description]

      Stemcell.new(resource, image)
    end

    private

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

      params
    end

    def logger
      Bosh::Clouds::Config.logger
    end
  end
end
