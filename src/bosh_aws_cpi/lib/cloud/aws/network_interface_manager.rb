module Bosh::AwsCloud
  class NetworkInterfaceManager
    include Helpers

    def initialize(ec2_resource, logger)
      @ec2_resource = ec2_resource
      @logger = logger
    end

    def create_network_interfaces(networks_cloud_props, vm_cloud_props, default_security_groups)
      nic_groups = {}
      security_group_mapper = SecurityGroupMapper.new(@ec2_resource)

      manual_networks = networks_cloud_props.networks.select { |network| network.type == 'manual' }
      first_dynamic_network = networks_cloud_props.networks.select { |network| network.type == 'dynamic' }.first #nic groups are not supported for multiple dynamic networks
      manual_networks.group_by(&:nic_group).map do |nic_group_name, networks|
        nic_groups[nic_group_name] = Bosh::AwsCloud::NicGroup.new(nic_group_name, networks)
      end

      if first_dynamic_network
        nic_groups[first_dynamic_network.name] = Bosh::AwsCloud::NicGroup.new(first_dynamic_network.name, [first_dynamic_network])
      end

      validate_subnet_az_mapping(nic_groups)

      provision_network_interfaces(nic_groups, networks_cloud_props, vm_cloud_props, default_security_groups, security_group_mapper)
    end

    def set_delete_on_termination_for_network_interfaces(network_interfaces)
      #we need to get the objects again from aws to update the attachment on the network interface objects
      network_interface_ids = network_interfaces.map(&:id)
      @ec2_resource.client.describe_network_interfaces({
        network_interface_ids: network_interface_ids
      }).network_interfaces.each do |nic|
        attachment = nic.attachment
        if attachment
          attachment_id = attachment.attachment_id
          @logger.info("Setting delete_on_termination for network_interface '#{nic.network_interface_id}' and attachment id '#{attachment_id}' to true")
          @ec2_resource.client.modify_network_interface_attribute({
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
        if nic_group.manual?
          nic[:ipv_6_addresses] = [{ ipv_6_address: nic_group.ipv6_address }] if nic_group.has_ipv6_address?
          nic[:private_ip_address] = nic_group.ipv4_address if nic_group.has_ipv4_address?
        end

        prefixes = nic_group.prefixes
        begin
          network_interface = nil
          errors = [Aws::EC2::Errors::InvalidIPAddressInUse]
          @logger.info("Creating new network_interface with: #{nic.inspect}")
          Bosh::Common.retryable(sleep: network_interface_create_wait_time, tries: 20, on: errors) do |_tries, error|
            @logger.info('Launching network interface...')
            @logger.warn("IP address was in use: #{error}") if error.is_a?(Aws::EC2::Errors::InvalidIPAddressInUse)

            resp = @ec2_resource.client.create_network_interface(nic)
            network_interface_id = get_created_network_interface_id(resp)
            network_interface = Bosh::AwsCloud::NetworkInterface.new(@ec2_resource.network_interface(network_interface_id), @ec2_resource.client, @logger)
            network_interface.wait_until_available
            network_interface.attach_ip_prefixes(prefixes) unless prefixes.nil?
            network_interface.add_associate_public_ip_address(vm_cloud_props)
            nic_group.assign_mac_address(network_interface.mac_address)
            network_interfaces.append(network_interface)
          end
        rescue => e
          @logger.error("Failed to create network interface for nic_group '#{nic_group.name}': #{e.inspect}")
          network_interfaces&.each { |nic| nic.delete }
          network_interface.delete if network_interface
          raise Bosh::Clouds::CloudError, "Failed to create network interface for nic_group '#{nic_group.name}': #{e.message}"
        end
      end
      return network_interfaces
    end

    def network_interface_create_wait_time
      Bosh::AwsCloud::NetworkInterface::CREATE_NETWORK_INTERFACE_WAIT_TIME
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

      availability_zones = @ec2_resource.subnets(
        filters: [{ name: 'subnet-id', values: subnet_ids }]
      ).map(&:availability_zone).uniq

      if availability_zones.size > 1
        raise Bosh::Clouds::CloudError, "All nic groups must be in the same availability zone. Found subnets in zones: #{availability_zones.join(', ')}"
      end
    end
  end
end
