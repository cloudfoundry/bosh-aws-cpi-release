module Bosh::AwsCloud
  class Stemcell
    include Helpers

    attr_reader :ami, :snapshots

    def self.find(client, id)
      image = client.image(id)
      raise Bosh::Clouds::CloudError, "could not find AMI '#{id}'" unless image.exists?
      new(client, image)
    end

    def initialize(client, image)
      @client = client
      @ami = image
      @snapshots = []
    end

    def delete
      memoize_snapshots

      ami.deregister

      # Wait for the AMI to be deregistered, or the snapshot deletion will fail,
      # as the AMI is still in use.
      ResourceWait.for_image(image: ami, state: :deleted)

      delete_snapshots
      logger.info("deleted stemcell '#{id}'")
    end

    def id
      ami.id
    end

    def image_id
      ami.id
    end

    def root_device_name
      ami.root_device_name
    end

    def memoize_snapshots
      # .to_hash is used as the AWS API documentation isn't trustworthy:
      # it says block_device_mappings retruns a Hash, but in reality it flattens it!
      ami.block_device_mappings.to_hash.each do |device, map|
        snapshot_id = map[:snapshot_id]
        if id
          logger.debug("queuing snapshot '#{snapshot_id}' for deletion")
          snapshots << snapshot_id
        end
      end
    end

    def delete_snapshots
      snapshots.each do |id|
        logger.info("cleaning up snapshot '#{id}'")
        snapshot = @client.snapshots[id]
        snapshot.delete
      end
    end

    def logger
      Bosh::Clouds::Config.logger
    end
  end
end
