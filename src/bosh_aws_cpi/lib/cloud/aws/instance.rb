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
      addresses = @aws_instance.vpc_addresses
      if addresses.count == 0
        nil
      else
        addresses.first.public_ip
      end
    end

    def associate_elastic_ip(elastic_ip)
      elastic_ip = Aws::EC2::VpcAddress.new(elastic_ip)
      elastic_ip.associate({
        instance_id: @aws_instance.id,
      })
    end

    def disassociate_elastic_ip
      addresses = @aws_instance.vpc_addresses
      if addresses.count == 0
        raise Bosh::Clouds::CloudError, 'Cannot call `disassociate_elastic_ip` on an Instance without an attached Elastic IP'
      else
        addresses.first.association.delete
      end
    end

    def source_dest_check=(state)
      @aws_instance.modify_attribute({
        source_dest_check: {
          value: state,
        },
      })
    end

    def wait_for_running
      # If we time out, it is because the instance never gets from state running to started,
      # so we signal the director that it is ok to retry the operation. At the moment this
      # forever (until the operation is cancelled by the user).
      begin
        @logger.info("Waiting for instance to be ready...")
        ResourceWait.for_instance(instance: @aws_instance, state: 'running')
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
      rescue Aws::EC2::Errors::InvalidInstanceIDNotFound => e
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
        ResourceWait.for_instance(instance: @aws_instance, state: 'terminated')
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
          @logger.debug("Finding routing table '#{definition['table_id']}'")
          table = tables.find { |t| t.id == definition['table_id'] }
          @logger.debug("Sending traffic for '#{definition['destination']}' to '#{@aws_instance.id}' in '#{definition['table_id']}'")

          existing_route = table.routes.find {|route| route.destination_cidr_block == definition['destination'] }
          if existing_route
            existing_route.replace({
              instance_id: @aws_instance.id,
            })
          else
            table.create_route({
              destination_cidr_block: definition['destination'],
              instance_id: @aws_instance.id,
            })
          end
        end
      end
    end

    def attach_to_load_balancers(load_balancer_ids)
      load_balancer_ids.each do |load_balancer_id|
        lb = @elb.register_instances_with_load_balancer({
          instances: [
            {
              instance_id: @aws_instance.id
            }
          ],
          load_balancer_name: load_balancer_id,
        })
      end
    end
  end
end
