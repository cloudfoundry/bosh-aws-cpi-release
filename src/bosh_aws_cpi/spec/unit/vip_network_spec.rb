require 'spec_helper'

describe Bosh::AwsCloud::VipNetwork do
  let(:ec2_resource) { instance_double(Aws::EC2::Resource, client: ec2_client) }
  let(:ec2_client) { instance_double(Aws::EC2::Client) }
  let(:instance) { instance_double(Aws::EC2::Instance, :id => 'fake-id') }

  before(:each) do
    allow(Kernel).to receive(:sleep)
  end

  it 'should require an IP' do
    vip = described_class.new('vip', {})
    expect {
      vip.configure(ec2_resource, instance)
    }.to raise_error Bosh::Clouds::CloudError
  end

  [Aws::EC2::Errors::IncorrectInstanceState.new(nil, 'bad-state'), Aws::EC2::Errors::InvalidInstanceID.new(nil, 'bad-id')].each do |error|
    context "when AWS returns an #{error} error" do
      it 'should retry to attach until it succeeds' do
        vip = described_class.new('vip', {'ip' => '1.2.3.4'})

        expect(ec2_client).to receive(:associate_address)
          .with(instance_id: 'fake-id', public_ip: '1.2.3.4')
          .and_raise(error)
        expect(ec2_client).to receive(:associate_address)
          .with(instance_id: 'fake-id', public_ip: '1.2.3.4')
          .and_return(true)

        vip.configure(ec2_resource, instance)
      end
    end
  end

end
