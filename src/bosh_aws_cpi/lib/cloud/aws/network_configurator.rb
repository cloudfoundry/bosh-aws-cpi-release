# Copyright (c) 2009-2012 VMware, Inc.

module Bosh::AwsCloud
  ##
  # Represents AWS instance network config. EC2 instance has single NIC
  # with dynamic IP address and (optionally) a single elastic IP address
  # which instance itself is not aware of (vip). Thus we should perform
  # a number of sanity checks for the network spec provided by director
  # to make sure we don't apply something EC2 doesn't understand how to
  # deal with.
  #
  class NetworkConfigurator
    include Helpers

    ##
    # Creates new network spec
    #
    # @param [Hash] spec raw network spec passed by director
    def initialize(network_cloud_props)
      @logger = Bosh::Clouds::Config.logger
      @vip_network = nil

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

      # AWS accounts that support both EC2-VPC and EC2-Classic platform access explicitly require allocation_id instead of public_ip
      addresses = AwsProvider.with_aws do
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

      # New elastic IP reservation supposed to clear the old one,
      # so no need to disassociate manually. Also, we don't check
      # if this IP is actually an allocated EC2 elastic IP, as
      # API call will fail in that case.

      errors = [Aws::EC2::Errors::IncorrectInstanceState, Aws::EC2::Errors::InvalidInstanceID]
      AwsProvider.with_aws do
        Bosh::Common.retryable(tries: 10, sleep: 1, on: errors) do
          ec2.client.associate_address(instance_id: instance.id, allocation_id: allocation_id)
          true # need to return true to end the retries
        end
      end
    end
  end
end