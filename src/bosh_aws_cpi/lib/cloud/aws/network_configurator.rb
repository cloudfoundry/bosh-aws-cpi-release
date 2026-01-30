# Copyright (c) 2009-2012 VMware, Inc.

module Bosh::AwsCloud
  ##
  # Represents AWS instance network configuration.
  # Handles Elastic IP (VIP) association to network interfaces.
  #
  class NetworkConfigurator
    include Helpers

    # @param [NetworkCloudProps] network_cloud_props parsed network configuration
    def initialize(network_cloud_props)
      @logger = Bosh::Clouds::Config.logger
      @vip_network = nil
      @network_cloud_props = network_cloud_props

      network_cloud_props.networks.each do |net|
        if net.instance_of?(Bosh::AwsCloud::NetworkCloudProps::PublicNetwork)
          cloud_error("More than one vip network for '#{net.name}'") if @vip_network
          @vip_network = net
        end
      end
    end

    # Applies network configuration to the vm
    # @param [AWS:EC2] ec2 instance EC2 client
    # @param [Aws::EC2::Instance] instance EC2 instance to configure
    def configure(ec2, instance)
      if @vip_network
        configure_vip(ec2, instance)
      else
        # If there is no vip network we should disassociate any elastic IP
        # currently held by instance (as it might have had elastic IP before)
        elastic_ip = instance.elastic_ip

        if elastic_ip
          @logger.info("Disassociating elastic IP `#{elastic_ip}' " \
                       "from instance `#{instance.id}'")
          instance.disassociate_elastic_ip
        end
      end
    end

    private

    def configure_vip(ec2, instance)
      if @vip_network.ip.nil?
        cloud_error("No IP provided for vip network '#{@vip_network.name}'")
      end

      describe_address_errors = [
        Aws::EC2::Errors::ServiceError,
        Aws::EC2::Errors::RequestLimitExceeded
      ]

      addresses = Bosh::Common.retryable(tries: 10, sleep: 1, on: describe_address_errors) do
        ec2.client.describe_addresses(
          public_ips: [@vip_network.ip],
          filters: [
            name: 'domain',
            values: [
              'vpc'
            ]
          ]
        ).addresses
      end

      found_address = addresses.first
      cloud_error("Elastic IP with VPC scope not found with address '#{@vip_network.ip}'") if found_address.nil?

      allocation_id = found_address.allocation_id

      @logger.info("Associating instance `#{instance.id}' " \
                   "with elastic IP `#{@vip_network.ip}' and allocation_id '#{allocation_id}'")

      describe_errors = [
        Aws::EC2::Errors::ServiceError,
        Aws::EC2::Errors::RequestLimitExceeded,
        Aws::EC2::Errors::InvalidInstanceID
      ]

      network_interfaces = Bosh::Common.retryable(tries: 10, sleep: 1, on: describe_errors) do
        response = ec2.client.describe_instances(instance_ids: [instance.id])
        if response.reservations.empty? || response.reservations.first.instances.empty?
          raise Aws::EC2::Errors::InvalidInstanceID.new(nil, "Instance '#{instance.id}' not found in describe_instances response")
        end
        response.reservations.first.instances.first.network_interfaces
      end

      if network_interfaces.nil? || network_interfaces.empty?
        cloud_error("No network interfaces found for instance '#{instance.id}'. " \
                    "Instance may not be fully initialized.")
      end

      target_device_index = determine_nic_index

      target_nic = network_interfaces.find { |nic| nic.attachment.device_index == target_device_index }

      if target_nic.nil?
        nic_indexes = network_interfaces.map { |nic| nic.attachment.device_index }.sort.join(', ')

        nic_group_info = @vip_network.nic_group ? "nic_group '#{@vip_network.nic_group}'" : "default (nic_group not specified)"
        cloud_error("Could not find network interface with device_index #{target_device_index} " \
                    "(#{nic_group_info}) on instance '#{instance.id}'. " \
                    "Found network interfaces with device indexes: #{nic_indexes}")
      end

      nic_group_info = @vip_network.nic_group ? "nic_group '#{@vip_network.nic_group}'" : "default (nic_group not specified)"
      @logger.info("Associating elastic IP with network interface '#{target_nic.network_interface_id}' " \
                   "(device_index #{target_device_index}, #{nic_group_info}) on instance '#{instance.id}'")

      errors = [Aws::EC2::Errors::IncorrectInstanceState, Aws::EC2::Errors::InvalidInstanceID]
      Bosh::Common.retryable(tries: 10, sleep: 1, on: errors) do
        ec2.client.associate_address(
          network_interface_id: target_nic.network_interface_id,
          allocation_id: allocation_id
        )
        true
      end
    end

    # Maps VIP network's nic_group to the corresponding device_index
    # Returns 0 (primary NIC) if nic_group is not specified or not found
    def determine_nic_index
      return 0 unless @vip_network.nic_group

      nic_groups = @network_cloud_props.networks
        .select { |net| (net.type == 'manual' || net.type == 'dynamic') && net.respond_to?(:nic_group) && net.nic_group }
        .map { |net| net.nic_group }
        .uniq

      device_index = nic_groups.index(@vip_network.nic_group)
      
      device_index || 0
    end
  end
end
