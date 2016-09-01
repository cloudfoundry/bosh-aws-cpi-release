module Bosh::AwsCloud
  class Instance
    include Helpers

    def initialize(aws_instance, registry, elb, logger)
      @aws_instance = aws_instance
      @registry = registry
      @elb = elb
      @logger = logger
    end

    def id
      @aws_instance.id
    end

    def elastic_ip
      @aws_instance.elastic_ip
    end

    def associate_elastic_ip(elastic_ip)
      @aws_instance.associate_elastic_ip(elastic_ip)
    end

    def disassociate_elastic_ip
      @aws_instance.disassociate_elastic_ip
    end

    def source_dest_check=(state)
      @aws_instance.source_dest_check = state
    end

    def wait_for_running
      # If we time out, it is because the instance never gets from state running to started,
      # so we signal the director that it is ok to retry the operation. At the moment this
      # forever (until the operation is cancelled by the user).
      begin
        @logger.info("Waiting for instance to be ready...")
        ResourceWait.for_instance(instance: @aws_instance, state: :running)
      rescue Bosh::Common::RetryCountExceeded
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
      rescue AWS::EC2::Errors::InvalidInstanceID::NotFound => e
        @logger.warn("Failed to terminate instance '#{@aws_instance.id}' because it was not found: #{e.inspect}")
        raise Bosh::Clouds::VMNotFound, "VM `#{@aws_instance.id}' not found"
      ensure
        @logger.info("Deleting instance settings for '#{@aws_instance.id}'")
        @registry.delete_settings(@aws_instance.id)
      end

      if fast
        TagManager.tag(@aws_instance, "Name", "to be deleted")
        @logger.info("Instance #{@aws_instance.id} marked to deletion")
        return
      end

      begin
        @logger.info("Deleting instance '#{@aws_instance.id}'")
        ResourceWait.for_instance(instance: @aws_instance, state: :terminated)
      rescue AWS::EC2::Errors::InvalidInstanceID::NotFound => e
        @logger.debug("Failed to find terminated instance '#{@aws_instance.id}' after deletion: #{e.inspect}")
        # It's OK, just means that instance has already been deleted
      end
    end

    # Determines if the instance exists.
    def exists?
      @aws_instance.exists? && @aws_instance.status != :terminated
    end

    def update_routing_tables(route_definitions)
      if route_definitions.length > 0
        @logger.debug("Associating instance with destinations in the routing tables")
        tables = @aws_instance.vpc.route_tables
        route_definitions.each do |definition|
          @logger.debug("Finding routing table '#{definition["table_id"]}'")
          table = tables[definition["table_id"]]
          @logger.debug("Sending traffic for '#{definition["destination"]}' to '#{@aws_instance.id}' in '#{definition["table_id"]}'")

          if table.routes.any? {|route| route.destination_cidr_block == definition["destination"] }
            table.replace_route(definition["destination"], { :instance => @aws_instance })
          else
            table.create_route(definition["destination"], { :instance => @aws_instance })
          end
        end
      end
    end

    def attach_to_load_balancers(load_balancer_ids)
      load_balancer_ids.each do |load_balancer_id|
        lb = @elb.load_balancers[load_balancer_id]
        lb.instances.register(@aws_instance)
      end
    end
  end
end
