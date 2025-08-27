module Bosh::AwsCloud
  class AgentSettings

    attr_accessor :agent_disk_info, :agent_config, :root_device_name
    attr_accessor :agent_id, :environment

    # Generates initial agent settings. These settings will be read by agent
    # from AWS registry (also a BOSH component) on a target instance. Disk
    # conventions for amazon are:
    # system disk: /dev/sda
    # ephemeral disk: /dev/sdb
    # EBS volumes can be configured to map to other device names later (sdf
    # through sdp, also some kernels will remap sd* to xvd*).
    #
    # @param [Hash] registry Registry endpoint. e.g. {endpoint: ...}
    # @param [Bosh::AwsCloud::NetworkCloudProps] network_props
    # @param [Hash] dns A hash containing a nameserver. e.g. {nameserver: ...}
    def initialize(registry, network_props, dns)
      @vm_id = "vm-#{SecureRandom.uuid}"
      @networks = agent_network_spec(network_props)
      @dns = dns
      @registry = registry
    end

    def agent_settings
      {
        'vm' => {
          'name' => @vm_id
        },
        'agent_id' => @agent_id,
        'networks' => @networks,
        'disks' => {
          'system' => @root_device_name,
          'persistent' => {}
        }
      }.tap do |settings|
        settings['disks'].merge!(@agent_disk_info)
        unless settings['disks']['ephemeral'].nil?
          settings['disks']['ephemeral'] = settings['disks']['ephemeral'][0]['path']
        end

        settings['env'] = @environment if @environment

        settings.merge!(@agent_config.to_h)
      end
    end

    def user_data
      userdata = {
        'dns' => @dns,
        'networks' => @networks
      }
      userdata.merge!({'registry' => @registry}) unless @registry.nil?
      userdata
    end

    def encode(version)
      Base64.encode64(settings_for_version(version).to_json).strip
    end

    def settings_for_version(version)
      case version
        when nil
          raise Bosh::Clouds::CPIAPIVersionNotSupported, "Stemcell API version '#{version}' is not supported."
        when 1
          user_data
        else
          agent_settings.merge(user_data)
      end
    end

    def update_agent_settings(network_cloud_props)
      @networks = agent_network_spec(network_cloud_props)
    end

    private
    def agent_network_spec(networks_cloud_props)
      spec = networks_cloud_props.networks.map do |net|
        settings = net.to_h
        settings['use_dhcp'] = true

        [net.name, settings]
      end
      Hash[spec]
    end
  end
end