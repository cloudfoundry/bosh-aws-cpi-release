module Bosh::AwsCloud
  class ClassicLB
    def initialize(client:, elb_name:)
      @client = client
      @elb_name = elb_name
    end

    def register(instance_id)
      @client.register_instances_with_load_balancer(
        instances: [
          {
            instance_id: instance_id,
          }
        ],
        load_balancer_name: @elb_name,
      )
    end
  end
end
