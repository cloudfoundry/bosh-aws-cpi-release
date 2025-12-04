module Bosh::AwsCloud
  class NetworkInterface
    include Helpers

    CREATE_NETWORK_INTERFACE_WAIT_TIME = 30
    DELETE_NETWORK_INTERFACE_WAIT_TIME = 10
    RETRYABLE_ERRORS = [Aws::EC2::Errors::InvalidNetworkInterfaceInUse, Aws::EC2::Errors::InvalidParameterValue]

    def initialize(aws_network_interface, ec2_client, logger)
      @aws_network_interface = aws_network_interface
      @ec2_client = ec2_client
      @logger = logger
    end

    def id
      @aws_network_interface.id
    end

    def wait_until_available
      begin
        @logger.info("Waiting for network interface to become available...")
        @ec2_client.wait_until(:network_interface_available, network_interface_ids: [id])
      rescue Aws::Waiters::Errors::TooManyAttemptsError
        message = "Timed out waiting for network interface '#{id}' to become available"
        @logger.warn(message)
        raise Bosh::Clouds::CloudError, message
      end
    end

    def attach_ip_prefixes(prefixes)
      return unless prefixes

      if prefixes[:ipv4]
        prefix_v4 = prefixes[:ipv4]
        @ec2_client.assign_private_ip_addresses(
          network_interface_id: id,
          ipv_4_prefixes: ["#{prefix_v4[:address]}/#{prefix_v4[:prefix]}"] # aws only supports /28 prefixes
        )
      end

      if prefixes[:ipv6]
        prefix_v6 = prefixes[:ipv6]
        @ec2_client.assign_ipv_6_addresses(
          network_interface_id: id,
          ipv_6_prefixes: ["#{prefix_v6[:address]}/#{prefix_v6[:prefix]}"] # aws only supports /80 prefixes
        )
      end
    end

    def add_associate_public_ip_address(vm_type)
      if vm_type.auto_assign_public_ip
        @logger.info("Associating public IP address with network interface '#{id}'")
        @ec2_client.modify_network_interface_attribute(
          network_interface_id: id,
          associate_public_ip_address: true
        )
      end
    rescue Aws::EC2::Errors::InvalidParameterValue => e
      @logger.error("Failed to associate public IP address: #{e.message}")
      raise Bosh::Clouds::CloudError, "Failed to associate public IP address: #{e.message}"
    end

    def delete
      begin
        @logger.info("Deleting network_interface: #{@aws_network_interface.id}")

        Bosh::Common.retryable(sleep: Bosh::AwsCloud::NetworkInterface::DELETE_NETWORK_INTERFACE_WAIT_TIME, tries: 50, on: RETRYABLE_ERRORS) do |_tries, error|
          if RETRYABLE_ERRORS.include?(error.class)
            @logger.warn("Network Interface was in use: #{error}. Retrying deletion after #{Bosh::AwsCloud::NetworkInterface::DELETE_NETWORK_INTERFACE_WAIT_TIME} seconds...")
          end
          @aws_network_interface.delete
          true
        end
      rescue => e
        @logger.warn("Failed to delete network interface '#{@aws_network_interface.id}' could not be deleted: #{e.inspect}")
      end
    end

    def mac_address
      @aws_network_interface.mac_address
    end

    def availability_zone
      @aws_network_interface.availability_zone
    end

    def ipv6_address?(address)
      # Check if the address contains a colon, which is characteristic of IPv6
      address.include?(':')
    end

    def nic_configuration(device_index)
      nic = {}

      nic[:device_index] = device_index
      nic[:network_interface_id] = @aws_network_interface.id

      nic
    end
  end
end
