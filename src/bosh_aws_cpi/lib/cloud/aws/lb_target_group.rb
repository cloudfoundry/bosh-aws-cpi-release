module Bosh::AwsCloud
  class LBTargetGroup
    include Helpers
    def initialize(client:, group_name:)
      @client = client
      @group_name = group_name
    end

    def register(target_id)
      @client.register_targets(
        target_group_arn: target_arn,
        targets: [{id: target_id}]
      )
    end

    private

    def target_arn
      return @target_arn if @target_arn

      resp = nil

      begin
        resp = @client.describe_target_groups(names: [@group_name])
      rescue Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound
        cloud_error("Cloud not find ALB target group `#{@group_name}'")
      end

      @target_arn = resp.target_groups[0].target_group_arn
      @target_arn
    end
  end
end
