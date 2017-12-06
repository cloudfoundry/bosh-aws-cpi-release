require 'integration/spec_helper'

describe Bosh::AwsCloud::LBTargetGroup do
  let(:elb_v2_client) do
    Aws::ElasticLoadBalancingV2::Client.new(
      access_key_id: @access_key_id,
      secret_access_key: @secret_access_key,
      session_token:  @session_token,
      region: @region,
    )
  end

  let(:target_group_name) { ENV.fetch('BOSH_AWS_TARGET_GROUP_NAME') }
  let(:instance_id) { create_vm }

  after do
    delete_vm(instance_id)
  end

  it 'registers new instance with target group' do
    target_group = Bosh::AwsCloud::LBTargetGroup.new(
      client: elb_v2_client,
      group_name: target_group_name,
    )
    target_group.register(instance_id)

    wait_for_target_state(
      target_group_name: target_group_name,
      target_id: instance_id,
      target_state: 'unhealthy',
    )
  end

  context 'when target_group_name does not exist' do
    let(:target_group_name) { 'fake-target-group' }

    it 'returns an error' do
      target_group = Bosh::AwsCloud::LBTargetGroup.new(
        client: elb_v2_client,
        group_name: target_group_name,
      )

      expect {
        target_group.register(instance_id)
      }.to raise_error(Bosh::Clouds::CloudError, /#{target_group_name}/)
    end
  end

  def wait_for_target_state(target_group_name:, target_state:, target_id:)
    health_state = nil
    20.times do
      health_description = elb_v2_client.describe_target_health(
        {
          target_group_arn: get_target_group_arn(target_group_name),
          targets: [id: target_id]
        }
      ).target_health_descriptions.first

      expect(health_description.target.id).to eq(target_id)
      health_state = health_description.target_health.state
      break if health_state == target_state
      sleep(3)
    end
    expect(health_state).to eq(target_state)
  end

  def get_target_group_arn(name)
    elb_v2_client.describe_target_groups(names: [name]).target_groups[0].target_group_arn
  end
end
