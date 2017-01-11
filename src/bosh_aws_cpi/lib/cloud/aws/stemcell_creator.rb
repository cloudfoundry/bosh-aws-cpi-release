module Bosh::AwsCloud
  class StemcellCreator
    include Bosh::Exec
    include Helpers

    attr_reader :client, :properties
    attr_reader :volume, :device_path, :image_path

    def initialize(client, properties)
      @client = client
      @properties = properties
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
      image = client.images[client.client.register_image(params).image_id]
      ResourceWait.for_image(image: image, state: 'available')

      TagManager.tag(image, 'Name', params[:description]) if params[:description]

      Stemcell.new(client, image)
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
      stemcell_copy = find_in_path("stemcell-copy")

      if stemcell_copy
        logger.debug("copying stemcell using stemcell-copy script")
        # note that is is a potentially dangerous operation, but as the
        # stemcell-copy script sets PATH to a sane value this is safe
        command = "sudo -n #{stemcell_copy} #{image_path} #{device_path} 2>&1"
      else
        logger.info("falling back to using included copy stemcell")
        included_stemcell_copy = File.expand_path("../../../../bin/stemcell-copy", __FILE__)
        command = "sudo -n #{included_stemcell_copy} #{image_path} #{device_path} 2>&1"
      end

      result = sh(command)

      logger.debug("stemcell copy output:\n#{result.output}")
    rescue Bosh::Exec::Error => e
      raise Bosh::Clouds::CloudError, "Unable to copy stemcell root image: #{e.message}\nScript output:\n#{e.output}"
    end

    # checks if the stemcell-copy script can be found in
    # the current PATH
    def find_in_path(command, path=ENV["PATH"])
      path.split(":").each do |dir|
        stemcell_copy = File.join(dir, command)
        return stemcell_copy if File.exist?(stemcell_copy)
      end
      nil
    end

    def image_params(snapshot_id)
      architecture = properties["architecture"]
      virtualization_type = properties["virtualization_type"] || "hvm"

      params = begin
        if virtualization_type == 'paravirtual'
          root_device_name = properties["root_device_name"]
          aki = properties['kernel_id'] || AKIPicker.new(client).pick(architecture, root_device_name)
          {
            :kernel_id => aki,
            :root_device_name => root_device_name,
            :block_device_mappings => [
              {
                :device_name => "/dev/sda",
                :ebs => {
                  :snapshot_id => snapshot_id,
                },
              },
            ],
          }
        else
          {
            :virtualization_type => virtualization_type,
            :root_device_name => "/dev/xvda",
            :sriov_net_support => "simple",
            :block_device_mappings => [
              {
                :device_name => "/dev/xvda",
                :ebs => {
                  :snapshot_id => snapshot_id,
                },
              },
            ],
          }
        end
      end

      # old stemcells doesn't have name & version
      if properties["name"] && properties["version"]
        name = "#{properties['name']} #{properties['version']}"
        params[:description] = name
      end

      params.merge!(
        :name => "BOSH-#{SecureRandom.uuid}",
        :architecture => architecture,
      )

      params[:block_device_mappings].push(BlockDeviceManager.default_instance_storage_disk_mapping)

      params
    end

    private

    def logger
      Bosh::Clouds::Config.logger
    end
  end
end
