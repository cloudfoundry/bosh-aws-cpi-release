module Bosh::AwsCloud
  module StemcellImageParams
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
  end
end
