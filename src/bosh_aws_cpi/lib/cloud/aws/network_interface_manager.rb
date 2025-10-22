module Bosh::AwsCloud
  class NetworkInterfaceManager
    include Helpers

    def initialize(ec2, logger)
      @ec2 = ec2
      @logger = logger
    end

    def create_network_interfaces(networks_cloud_props, vm_cloud_props, default_security_groups)
      # Iterate over network cloud props and group networks by nic_group
      nic_groups = {}
      first_dynamic_network = nil
      security_group_mapper = SecurityGroupMapper.new(@ec2)

      networks_cloud_props.networks.each do |network|
        if network.type == 'manual'
          nic_group_name = network.nic_group
          nic_groups[nic_group_name] ||= Bosh::AwsCloud::NicGroup.new(nic_group_name)
          nic_groups[nic_group_name].add_network(network)
        elsif network.type == 'dynamic'
          # Capture the first dynamic network encountered
          first_dynamic_network ||= network
        end
      end

      # Add dynamic network to the nic_group structure if one was found
      if first_dynamic_network
        nic_groups[first_dynamic_network.name] = Bosh::AwsCloud::NicGroup.new(first_dynamic_network.name, [first_dynamic_network])
      end

      # Now validate and extract IP config for all nic groups
      nic_groups.each_value(&:validate_and_extract_ip_config)

      validate_subnet_az_mapping(nic_groups)

      provision_network_interfaces(nic_groups, networks_cloud_props, vm_cloud_props, default_security_groups, security_group_mapper)
    end

    def set_delete_on_termination_for_network_interfaces(network_interfaces)
      #we need to get the objects again from aws to update the attachment on the network interface objects
      network_interface_ids = network_interfaces.map(&:id)
      @ec2.client.describe_network_interfaces({
        network_interface_ids: network_interface_ids
      }).network_interfaces.each do |nic|
        attachment = nic.attachment
        if attachment
          attachment_id = attachment.attachment_id
          @logger.info("Setting delete_on_termination for network_interface '#{nic.network_interface_id}' and attachment id '#{attachment_id}' to true")
          @ec2.client.modify_network_interface_attribute({
            network_interface_id: nic.network_interface_id,
            attachment: {
              attachment_id: attachment_id,
              delete_on_termination: true
            }
          })
        else
          raise Bosh::Clouds::CloudError, "Network interface '#{nic.network_interface_id}' is not attached to any instance"
        end
      end
    end

    def delete_network_interfaces(network_interfaces)
      network_interfaces.each do |network_interface|
        network_interface.delete
      end
    end

    private

    def provision_network_interfaces(nic_groups, network_cloud_props, vm_cloud_props, default_security_groups, security_group_mapper)
      network_interfaces = []
      nic_groups.each_value do |nic_group|
        # Get subnet from the nic_group
        subnet_id_val = nic_group.subnet_id

        # Get security groups
        sg = security_group_mapper.map_to_ids(security_groups(network_cloud_props, vm_cloud_props, default_security_groups), subnet_id_val)

        if ( sg.nil? || sg.empty? )
          raise Bosh::Clouds::CloudError, "Missing security groups. See http://bosh.io/docs/aws-cpi.html for the list of supported properties."
        end

        nic = {}
        nic[:groups] = sg
        nic[:subnet_id] = subnet_id_val

        # Only populate addresses if the nic_group contains manual networks
        if nic_group.manual_network?
          nic[:ipv_6_addresses] = [{ ipv_6_address: nic_group.ipv6_address }] if nic_group.has_ipv6_address?
          nic[:private_ip_address] = nic_group.ipv4_address if nic_group.has_ipv4_address?
        end

        # Get prefixes from nic_group
        prefixes = nic_group.prefixes

        errors = [Aws::EC2::Errors::InvalidIPAddressInUse]
        @logger.info("Creating new network_interface with: #{nic.inspect}")
        Bosh::Common.retryable(sleep: Bosh::AwsCloud::NetworkInterface::CREATE_NETWORK_INTERFACE_WAIT_TIME, tries: 20, on: errors) do |_tries, error|
          @logger.info('Launching network interface...')
          @logger.warn("IP address was in use: #{error}") if error.is_a?(Aws::EC2::Errors::InvalidIPAddressInUse)

          resp = @ec2.client.create_network_interface(nic)
          network_interface_id = get_created_network_interface_id(resp)
          network_interface = Bosh::AwsCloud::NetworkInterface.new(@ec2.network_interface(network_interface_id), @ec2.client, @logger)
          network_interface.wait_until_available
          network_interface.attach_ip_prefixes(prefixes) unless prefixes.nil?
          network_interface.add_associate_public_ip_address(vm_cloud_props)
          nic_group.assign_mac_address(network_interface.mac_address)
          network_interfaces.append(network_interface)
        rescue => e
          @logger.error("Failed to create network interface for nic_group '#{nic_group.name}': #{e.inspect}")
          network_interfaces&.each { |nic| nic.delete }
          network_interface.delete if network_interface
          raise
        end
      end
      return network_interfaces
    end

    def get_created_network_interface_id(resp)
      resp.network_interface.network_interface_id
    end

    def security_groups(networks_cloud_props, vm_cloud_props, default_security_groups)
      networks_security_groups = networks_cloud_props.security_groups

      groups = default_security_groups
      groups = networks_security_groups unless networks_security_groups.empty?
      groups = vm_cloud_props.security_groups unless vm_cloud_props.security_groups.empty?
      groups
    end

    def validate_subnet_az_mapping(nic_groups)
      subnet_ids = nic_groups.values.map(&:subnet_id).compact.uniq

      return {} if subnet_ids.empty?

      availability_zones = @ec2.subnets(
        filters: [{ name: 'subnet-id', values: subnet_ids }]
      ).map(&:availability_zone).uniq

      if availability_zones.size > 1
        raise Bosh::Clouds::CloudError, "All nic groups must be in the same availability zone. Found subnets in zones: #{availability_zones.join(', ')}"
      end
    end
  end
end
