require 'spec_helper'

describe Bosh::AwsCloud::VipNetwork do
  let(:ec2_resource) { instance_double(Aws::EC2::Resource, client: ec2_client) }
  let(:ec2_client) { instance_double(Aws::EC2::Client) }
  let(:instance) { instance_double(Aws::EC2::Instance, :id => 'fake-id') }
  let(:eip) { '1.2.3.4' }
  let(:describe_addresses_arguments) do
    {
      public_ips: ['1.2.3.4'],
      filters: [
        {
          name: 'domain',
          values: [
            'vpc',
          ]
        }
      ]
    }
  end

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
      let(:allocation_id) { 'eipalloc-fake' }
      let(:found_address) { instance_double(Aws::EC2::Types::Address, allocation_id: allocation_id)}
      let(:describe_addresses_response) { instance_double(Aws::EC2::Types::DescribeAddressesResult, addresses: [found_address]) }

      it 'should retry to attach until it succeeds' do
        vip = described_class.new('vip', {'ip' => eip})

        expect(ec2_client).to receive(:describe_addresses)
          .with(describe_addresses_arguments).and_return(describe_addresses_response)

        expect(ec2_client).to receive(:associate_address)
          .with(instance_id: 'fake-id', allocation_id: allocation_id)
          .and_raise(error)
        expect(ec2_client).to receive(:associate_address)
          .with(instance_id: 'fake-id', allocation_id: allocation_id)
          .and_return(true)

        vip.configure(ec2_resource, instance)
      end
    end
  end

  context 'when the user does not own the Elastic/Public IP' do
    let(:allocation_id) { 'eipalloc-fake' }
    let(:describe_addresses_response) { instance_double(Aws::EC2::Types::DescribeAddressesResult, addresses: []) }

    it 'should raise an error' do
      vip = described_class.new('vip', {'ip' => eip})

      expect(ec2_client).to receive(:describe_addresses)
        .with(describe_addresses_arguments).and_return(describe_addresses_response)

      expect {
        vip.configure(ec2_resource, instance)
      }.to raise_error(/Elastic IP with VPC scope not found with address/)
    end
  end
end
