require 'spec_helper'

describe Bosh::AwsCloud::CloudV1, 'delete_vm' do
  let(:instance_manager) { instance_double(Bosh::AwsCloud::InstanceManager) }
  let(:instance_id) { 'fake-id' }

  let(:cloud_core) { instance_double(Bosh::AwsCloud::CloudCore) }

  let(:registry) { instance_double(Bosh::Cpi::RegistryClient) }
  let(:cloud) {
    mock_cloud do |ec2|
      allow(Bosh::Cpi::RegistryClient).to receive(:new).and_return(registry)

      allow(registry).to receive(:endpoint).and_return('http://something.12.34.52')
      allow(Bosh::AwsCloud::InstanceManager).to receive(:new)
        .with(
          ec2,
          be_an_instance_of(Bosh::Cpi::Logger)
        ).and_return(instance_manager)
    end
  }

  before do
    allow(Bosh::AwsCloud::CloudCore).to receive(:new).and_return(cloud_core)
  end

  it 'deletes an EC2 instance' do
    expect(cloud_core).to receive(:delete_vm).with(instance_id).and_yield(instance_id)
    expect(registry).to receive(:delete_settings).with(instance_id)

    cloud.delete_vm(instance_id)
  end
end
