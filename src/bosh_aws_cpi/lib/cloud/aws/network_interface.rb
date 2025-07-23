module Bosh::AwsCloud
  class NetworkInterface
    include Helpers

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
        @ec2_client.wait_until(:network_interface_available, network_interface_ids: [@aws_network_interface.id])
      rescue Aws::Waiters::Errors::TooManyAttemptsError
        message = "Timed out waiting for network interface '#{@aws_instance.id}' to become available"
        @logger.warn(message)
        raise Bosh::Clouds::NetworkInterfaceCreationFailed.new(true), message
      end
    end

    def attach_ip_prefixes(private_ip_addresses)
      @logger.info("Attaching IP prefixes to network interface '#{private_ip_addresses.inspect}'")
      private_ip_addresses.each do |address|
          private_ip = address[:ip]
          prefix = address[:prefix].to_s
          if ipv6_address?(private_ip)
            if !prefix.empty? && prefix.to_i < 128
              @ec2_client.assign_ipv_6_addresses(
                network_interface_id: @aws_network_interface.id,
                ipv_6_prefixes: ["#{private_ip}/#{prefix}"] # aws only supports /80 prefixes
              )
            end
          else
            if !prefix.empty? && prefix.to_i < 32
              @ec2_client.assign_private_ip_addresses(
                network_interface_id: @aws_network_interface.id,
                ipv_4_prefixes: ["#{private_ip}/#{prefix}"] # aws only supports /28 prefixes
              )
            end
          end
      end
    end

    def ipv6_address?(addr)
      addr.to_s.include?(':')
    end

    def delete
      @aws_network_interface.delete
    end

    def mac_address
      @aws_network_interface.mac_address
    end

    def nic_configuration
      nic = {}

      nic[:device_index] = 0
      nic[:network_interface_id] = @aws_network_interface.id

      nic
    end
  end
end
