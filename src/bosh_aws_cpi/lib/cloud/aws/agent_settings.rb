module Bosh::AwsCloud
  class AgentSettings
    attr_reader :settings

    # Generates initial agent settings. These settings will be read by agent
    # from AWS registry (also a BOSH component) on a target instance. Disk
    # conventions for amazon are:
    # system disk: /dev/sda
    # ephemeral disk: /dev/sdb
    # EBS volumes can be configured to map to other device names later (sdf
    # through sdp, also some kernels will remap sd* to xvd*).
    #
    # @param [String] agent_id Agent id (will be picked up by agent to
    #   assume its identity
    # @param [Hash] network_spec Agent network spec
    # @param [Hash] environment
    # @param [String] root_device_name root device, e.g. /dev/sda1
    # @param [Hash] block_device_agent_info disk attachment information to merge into the disks section.
    #   keys are device type ("ephemeral", "raw_ephemeral") and values are array of strings representing the
    #   path to the block device. It is expected that "ephemeral" has exactly one value.
    # @param [Bosh::AwsCloud::AgentConfig] Global Agent configuration
    def initialize(agent_id, network_props, environment, root_device_name, block_device_agent_info, agent_config)
      @settings = {
        'vm' => {
          'name' => "vm-#{SecureRandom.uuid}"
        },
        'agent_id' => agent_id,
        'networks' => AgentSettings.agent_network_spec(network_props),
        'disks' => {
          'system' => root_device_name,
          'persistent' => {}
        }
      }

      @settings['disks'].merge!(block_device_agent_info)
      @settings['disks']['ephemeral'] = @settings['disks']['ephemeral'][0]['path']

      @settings['env'] = environment if environment

      @settings.merge!(agent_config.to_h)
    end

    def self.agent_network_spec(networks_cloud_props)
      spec = networks_cloud_props.networks.map do |net|
        settings = net.to_h
        settings['use_dhcp'] = true

        [net.name, settings]
      end
      Hash[spec]
    end
  end
end