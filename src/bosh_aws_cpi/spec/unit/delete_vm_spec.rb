require 'spec_helper'

describe Bosh::AwsCloud::CloudV1, 'delete_vm' do
  let(:instance_manager) { instance_double(Bosh::AwsCloud::InstanceManager) }
  let(:registry) { instance_double(Bosh::Cpi::RegistryClient) }
  let(:cloud) {
    mock_cloud do |ec2|
      registry = instance_double(Bosh::Cpi::RegistryClient)
      allow(Bosh::Cpi::RegistryClient).to receive(:new).and_return(registry)

      allow(registry).to receive(:endpoint).and_return('http://something.12.34.52')
      allow(Bosh::AwsCloud::InstanceManager).to receive(:new)
        .with(
          ec2,
          registry.endpoint,
          be_an_instance_of(Bosh::Cpi::Logger)
        ).and_return(instance_manager)

    end
  }

  #TODO registry_refator: add test to expect registry delete call at this stage
  it 'deletes an EC2 instance' do
    instance = instance_double(Bosh::AwsCloud::Instance)
    allow(instance_manager).to receive(:find).with('fake-id').and_return(instance)

    expect(instance).to receive(:terminate).with(false)

    cloud.delete_vm('fake-id')
  end
end
