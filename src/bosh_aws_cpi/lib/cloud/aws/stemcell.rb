module Bosh::AwsCloud
  class Stemcell
    include Helpers

    attr_reader :ami, :snapshots

    def self.find(resource, id)
      image = resource.image(id)
      raise Bosh::Clouds::CloudError, "could not find AMI '#{id}'" unless image.exists?
      new(resource, image)
    end

    def initialize(resource, image)
      @resource = resource
      @ami = image
      @snapshots = []
    end

    def delete
      memoize_snapshots

      ami.deregister

      # Wait for the AMI to be deregistered, or the snapshot deletion will fail,
      # as the AMI is still in use.
      ResourceWait.for_image(image: ami, state: 'deleted')

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

    private

    def memoize_snapshots
      ami.block_device_mappings.each do |device|
        if id && device.ebs
          snapshot_id = device.ebs.snapshot_id
          logger.debug("queuing snapshot '#{snapshot_id}' for deletion")
          snapshots << snapshot_id
        end
      end
    end

    def delete_snapshots
      snapshots.each do |id|
        logger.info("cleaning up snapshot '#{id}'")
        snapshot = @resource.snapshot(id)
        snapshot.delete
      end
    end

    def logger
      Bosh::Clouds::Config.logger
    end
  end
end
