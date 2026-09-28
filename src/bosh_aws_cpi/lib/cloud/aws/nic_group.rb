require 'ipaddr'

module Bosh::AwsCloud
  # Groups the networks that share a single ENI (nic_group) and derives the IP
  # configuration - IPv4/IPv6 addresses, prefixes, and the primary_ipv6 setting -
  # that the network-interface manager needs when creating that ENI.
  class NicGroup
    attr_reader :name, :networks, :ipv4_address, :ipv6_address

    # @param name [String] the nic_group identifier shared by the networks
    # @param networks [Array] the networks belonging to this nic_group; when any
    #   are given their IP configuration is validated and extracted immediately
    def initialize(name, networks = [])
      @name = name
      @networks = networks

      validate_and_extract_ip_config if networks.any?
    end

    # @return [String, nil] the subnet id shared by the group's networks
    def subnet_id
      first_network&.subnet
    end

    # @return [Boolean] true if the group's networks are manual networks
    def manual?
      first_network&.type == 'manual'
    end

    # @return [Boolean] true if the group's networks are dynamic networks
    def dynamic?
      first_network&.type == 'dynamic'
    end

    # @return [Array<String>] the names of the networks in this group
    def network_names
      @networks.map(&:name)
    end

    # @return [Boolean] true if an IPv4 address was configured for the group
    def has_ipv4_address?
      !@ipv4_address.nil?
    end

    # @return [Boolean] true if an IPv6 address was configured for the group
    def has_ipv6_address?
      !@ipv6_address.nil?
    end

    # @return [Boolean] true if a network requested a primary IPv6 address,
    #   i.e. enable_primary_ipv_6 should be set on the ENI
    def primary_ipv6?
      !!@primary_ipv6
    end

    # @return [Hash, nil] the configured IPv4 and/or IPv6 prefixes keyed by
    #   :ipv4/:ipv6, or nil when the group has no prefix networks
    def prefixes
      prefixes = {}
      prefixes[:ipv4] = @ipv4_prefix if @ipv4_prefix
      prefixes[:ipv6] = @ipv6_prefix if @ipv6_prefix
      prefixes.empty? ? nil : prefixes
    end

    # Propagates the ENI's MAC address to every network in the group.
    # @param mac_address [String] the MAC address assigned to the created ENI
    def assign_mac_address(mac_address)
      @networks.each do |network|
        network.mac = mac_address if network.respond_to?(:mac=)
      end
    end

    private

    # @return [Object, nil] the first network in the group, used for the
    #   group-wide attributes (subnet, type) shared by all its networks
    def first_network
      @networks.first
    end

    # Validates the group's networks and extracts its IP configuration: ensures a
    # single shared subnet, collects the IPv4/IPv6 addresses and prefixes, and
    # enforces the primary_ipv6 constraints (a matching GUA IPv6 address, and only
    # one primary IPv6 per group). Raises Bosh::Clouds::CloudError on any violation.
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
        mismatched = primary_ipv6_networks.reject { |n| same_ipv6_address?(n.ip, @ipv6_address) }
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

    # @param addr [String] an IP address string
    # @return [Boolean] true if the address is IPv6 (contains a colon)
    def ipv6_address?(addr)
      addr.to_s.include?(':')
    end

    # Compares two IPv6 addresses by their parsed value so that equivalent
    # spellings (compressed vs. expanded, e.g. 2001:db8::1 and
    # 2001:0db8:0000:0000:0000:0000:0000:0001) are treated as equal. Falls back
    # to a string comparison if either value cannot be parsed as an IP address.
    def same_ipv6_address?(a, b)
      IPAddr.new(a.to_s) == IPAddr.new(b.to_s)
    rescue IPAddr::Error
      a.to_s == b.to_s
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
