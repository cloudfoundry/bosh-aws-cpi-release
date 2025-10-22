module Bosh::AwsCloud
  class Instance
    include Helpers

    def initialize(aws_instance, logger)
      @aws_instance = aws_instance
      @logger = logger
    end

    def id
      @aws_instance.id
    end

    def elastic_ip
      addresses = @aws_instance.vpc_addresses
      if addresses.count.zero?
        nil
      else
        addresses.first.public_ip
      end
    end

    def associate_elastic_ip(elastic_ip)
      elastic_ip = Aws::EC2::VpcAddress.new(elastic_ip)
      elastic_ip.associate(
        instance_id: @aws_instance.id,
      )
    end

    def disassociate_elastic_ip
      addresses = @aws_instance.vpc_addresses
      if addresses.count.zero?
        raise Bosh::Clouds::CloudError, 'Cannot call `disassociate_elastic_ip` on an Instance without an attached Elastic IP'
      else
        addresses.first.association.delete
      end
    end

    def disable_dest_check
      @aws_instance.modify_attribute(
        source_dest_check: {
          value: false
        }
      )
    end

    def wait_until_exists
      # describe_instances will have no reservations in the response if the instance does not exist yet
      begin
        @logger.info("Waiting for instance to exist...")
        @aws_instance = @aws_instance.wait_until_exists
      rescue Aws::Waiters::Errors::TooManyAttemptsError
        message = "Timed out waiting for instance '#{@aws_instance.id}' to exist"
        @logger.warn(message)
        raise Bosh::Clouds::VMCreationFailed.new(true), message
      end
    end

    def wait_until_running
      # If we time out, it is because the instance never gets from state running to started,
      # so we signal the director that it is ok to retry the operation. At the moment this
      # forever (until the operation is cancelled by the user).
      begin
        @logger.info("Waiting for instance to be ready...")
        @aws_instance = @aws_instance.wait_until_running
      rescue Aws::Waiters::Errors::TooManyAttemptsError
        message = "Timed out waiting for instance '#{@aws_instance.id}' to be running"
        @logger.warn(message)
        raise Bosh::Clouds::VMCreationFailed.new(true), message
      end
    end

    # Soft reboots EC2 instance
    def reboot
      # There is no trackable status change for the instance being
      # rebooted, so it's up to CPI client to keep track of agent
      # being ready after reboot.
      # Due to this, we can't deregister the instance from any load
      # balancers it might be attached to, and reattach once the
      # reboot is complete, so we just have to let the load balancers
      # take the instance out of rotation, and put it back in once it
      # is back up again.
      @aws_instance.reboot
    end

    def terminate(fast=false)
      begin
        @aws_instance.terminate
      rescue Aws::EC2::Errors::InvalidInstanceIDNotFound => e
        @logger.warn("Failed to terminate instance '#{@aws_instance.id}' because it was not found: #{e.inspect}")
        raise Bosh::Clouds::VMNotFound, "VM `#{@aws_instance.id}' not found"
      ensure
        #TODO move this into v1
        @logger.info("Deleting instance settings for '#{@aws_instance.id}'")
      end

      if fast
        TagManager.tag(@aws_instance, "Name", "to be deleted")
        @logger.info("Instance #{@aws_instance.id} marked to deletion")
        return
      end

      begin
        @logger.info("Deleting instance '#{@aws_instance.id}'")
        @aws_instance = @aws_instance.wait_until_terminated
      rescue Aws::EC2::Errors::InvalidInstanceIDNotFound => e
        @logger.debug("Failed to find terminated instance '#{@aws_instance.id}' after deletion: #{e.inspect}")
        # It's OK, just means that instance has already been deleted
      end
    end

    # Determines if the instance exists.
    def exists?
      @aws_instance.exists? && @aws_instance.state.name != 'terminated'
    end

    def update_routing_tables(route_definitions)
      if route_definitions.length > 0
        @logger.debug('Associating instance with destinations in the routing tables')
        tables = @aws_instance.vpc.route_tables
        route_definitions.each do |definition|
          @logger.debug("Finding routing table '#{definition.table_id}'")
          table = tables.find { |t| t.id == definition.table_id }
          @logger.debug("Sending traffic for '#{definition.destination}' to '#{@aws_instance.id}' in '#{definition.table_id}'")

          existing_route = table.data.routes.find do |route|
            !route.nil? && route.destination_cidr_block == definition.destination
          end

          if existing_route
            route = Aws::EC2::Route.new(
              route_table_id: table.route_table_id,
              destination_cidr_block: existing_route.destination_cidr_block,
              data: existing_route,
              client: table.client,
            )
            route.replace(instance_id: @aws_instance.id)
          else
            table.create_route(destination_cidr_block: definition.destination, instance_id: @aws_instance.id)
          end
        end
      end
    end
  end
end
