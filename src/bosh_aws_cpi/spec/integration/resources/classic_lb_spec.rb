require 'integration/spec_helper'

describe Bosh::AwsCloud::ClassicLB do
  let(:elb_v1_client) do
    Aws::ElasticLoadBalancing::Client.new(
      access_key_id: @access_key_id,
      secret_access_key: @secret_access_key,
      region: @region,
    )
  end

  let(:elb_name) { ENV['BOSH_AWS_ELB_ID'] || raise('Missing BOSH_AWS_ELB_ID') }

  let(:instance_id) { create_vm }

  after do
    delete_vm(instance_id)
  end

  it 'registers new instance with ELB' do
    lb = Bosh::AwsCloud::ClassicLB.new(
      client: elb_v1_client,
      elb_name: elb_name,
    )

    lb.register(instance_id)

    lbs = elb_v1_client.describe_load_balancers(
      load_balancer_names: [
        elb_name,
      ],
    ).load_balancer_descriptions

    expect(lbs.length).to eq(1), "Expected to find 1 LB, but did not: #{lbs.inspect}"

    lb_instances = lbs.first.instances
    expect(lb_instances.length).to eq(1), "Expected to find 1 LB Instance, but did not: #{lb_instances.inspect}"

    expect(lb_instances.first.instance_id).to eq(instance_id)
  end
end
