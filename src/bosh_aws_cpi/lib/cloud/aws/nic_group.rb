module Bosh::AwsCloud
  class NicGroup
    attr_reader :name, :networks, :ipv4_address, :ipv6_address

    def initialize(name, networks = [])
      @name = name
      @networks = networks

      validate_and_extract_ip_config if networks.any?
    end

    def subnet_id
      first_network&.subnet
    end

    def manual?
      first_network&.type == 'manual'
    end

    def dynamic?
      first_network&.type == 'dynamic'
    end

    def network_names
      @networks.map(&:name)
    end

    def has_ipv4_address?
      !@ipv4_address.nil?
    end

    def has_ipv6_address?
      !@ipv6_address.nil?
    end

    def prefixes
      prefixes = {}
      prefixes[:ipv4] = @ipv4_prefix if @ipv4_prefix
      prefixes[:ipv6] = @ipv6_prefix if @ipv6_prefix
      prefixes.empty? ? nil : prefixes
    end

    def assign_mac_address(mac_address)
      @networks.each do |network|
        network.mac = mac_address if network.respond_to?(:mac=)
      end
    end

    private

    def first_network
      @networks.first
    end

    def validate_and_extract_ip_config
      subnet_ids = @networks.map(&:subnet).compact.uniq
      if subnet_ids.size > 1 || subnet_ids.empty?
        raise Bosh::Clouds::CloudError, "Networks in nic_group '#{@name}' have different subnet ids: #{subnet_ids.join(', ')} or probably none of them have any subnet id defined. All networks in a nic_group must have the same subnet_id."
      end

      @networks.each do |network|
        next unless network.respond_to?(:ip) && network.ip

        if ipv6_address?(network.ip)
          if network.prefix && network.prefix.to_i != 128
            @ipv6_prefix ||= { address: network.ip, prefix: network.prefix }
          else
            @ipv6_address ||= network.ip
          end
        else
          if network.prefix && network.prefix.to_i != 32
            @ipv4_prefix ||= { address: network.ip, prefix: network.prefix }
          else
            @ipv4_address ||= network.ip
          end
        end
      end

      unless has_ipv4_address? || has_ipv6_address? || dynamic?
        raise Bosh::Clouds::CloudError, "Could not find a single ip address for nic group '#{@name}' and a prefix network can only be a secondary network."
      end
    end

    def ipv6_address?(addr)
      addr.to_s.include?(':')
    end
  end
end
