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

    def primary_ipv6?
      !!@primary_ipv6
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

      primary_ipv6_networks = @networks.select { |n| n.respond_to?(:primary_ipv6) && n.primary_ipv6 }
      @primary_ipv6 = primary_ipv6_networks.any?

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

      # enable_primary_ipv_6 is valid on dual-stack ENIs (IPv4 + IPv6), so an IPv4
      # address alongside primary_ipv6 is allowed. It only requires an IPv6 address.
      if @primary_ipv6 && !has_ipv6_address?
        raise Bosh::Clouds::CloudError,
          "NicGroup '#{@name}' has primary_ipv6: true but no IPv6 address was specified."
      end

      # The address sent to the ENI (@ipv6_address, the first full IPv6 network) is
      # the one enable_primary_ipv_6 applies to. Every network flagged primary_ipv6
      # must therefore resolve to that same address; otherwise the flag and the
      # selected address would be mismatched (or two networks would demand different
      # primary addresses), so reject instead of silently promoting the wrong one.
      if @primary_ipv6 && has_ipv6_address?
        mismatched = primary_ipv6_networks.reject { |n| n.ip == @ipv6_address }
        unless mismatched.empty?
          names = mismatched.map { |n| "'#{n.name}' (#{n.ip})" }.join(', ')
          raise Bosh::Clouds::CloudError,
            "NicGroup '#{@name}' marks network(s) #{names} as primary_ipv6, but the selected IPv6 address is '#{@ipv6_address}'. The primary_ipv6 network must provide the group's IPv6 address, and only one primary IPv6 address is allowed per nic_group."
        end
      end

      # AWS assigns a global unicast address (GUA, 2000::/3) as the primary IPv6.
      # Any other class - unique local (fc00::/7), link-local (fe80::/10), multicast,
      # etc. - can never become a primary IPv6, so reject it up front with a clear
      # error instead of letting CreateNetworkInterface fail obscurely.
      if @primary_ipv6 && !global_unicast_ipv6?(@ipv6_address)
        raise Bosh::Clouds::CloudError,
          "NicGroup '#{@name}' has primary_ipv6: true but IPv6 address '#{@ipv6_address}' is not a global unicast address (GUA, 2000::/3). A primary IPv6 address must be a global unicast address."
      end
    end

    def ipv6_address?(addr)
      addr.to_s.include?(':')
    end

    # GUA range is 2000::/3: the leading three bits are 001, i.e. a leading hextet
    # of 2000-3fff (first byte 0x20-0x3f). ULA (fc00::/7), link-local (fe80::/10),
    # multicast (ff00::/8), and the unspecified/loopback addresses all fall outside.
    def global_unicast_ipv6?(addr)
      first_hextet = addr.to_s.split(':').first.to_s
      return false if first_hextet.empty?

      leading_byte = first_hextet.rjust(4, '0')[0, 2].to_i(16)
      leading_byte >= 0x20 && leading_byte <= 0x3f
    end
  end
end
