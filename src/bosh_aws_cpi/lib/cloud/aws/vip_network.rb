# Copyright (c) 2009-2012 VMware, Inc.

module Bosh::AwsCloud

  class VipNetwork < Network

    ##
    # Creates a new vip network
    #
    # @param [String] name Network name
    # @param [Hash] spec Raw network spec
    def initialize(name, spec)
      super
    end

    ##
    # Configures vip network
    #
    # @param [AWS::EC2::Resource] ec2 EC2 resource
    # @param [Aws::EC2::Instance] instance EC2 instance to configure
    def configure(ec2, instance)
      if @ip.nil?
        cloud_error("No IP provided for vip network `#{@name}'")
      end

      @logger.info("Associating instance `#{instance.id}' " \
                   "with elastic IP `#{@ip}'")

      # New elastic IP reservation supposed to clear the old one,
      # so no need to disassociate manually. Also, we don't check
      # if this IP is actually an allocated EC2 elastic IP, as
      # API call will fail in that case.

      errors = [Aws::EC2::Errors::IncorrectInstanceState, Aws::EC2::Errors::InvalidInstanceID]
      Bosh::Common.retryable(tries: 10, sleep: 1, on: errors) do
        ec2.client.associate_address(instance_id: instance.id, public_ip: @ip)
        true # need to return true to end the retries
      end
    end
  end
end
