require 'spec_helper'

describe Bosh::AwsCloud::Cloud, "delete_vm" do
  let(:instance_manager) { instance_double('Bosh::AwsCloud::InstanceManager') }
  let(:cloud) {
    mock_cloud do |ec2|
      registry = double("registry")
      allow(Bosh::Cpi::RegistryClient).to receive(:new).and_return(registry)

      allow(Bosh::AwsCloud::InstanceManager).to receive(:new).
        with(
          ec2,
          registry,
          be_an_instance_of(Aws::ElasticLoadBalancing::Client),
          be_an_instance_of(Bosh::AwsCloud::InstanceParamMapper),
          be_an_instance_of(Bosh::AwsCloud::BlockDeviceManager),
          be_an_instance_of(Logger)
        ).and_return(instance_manager)
    end
  }

  it 'deletes an EC2 instance' do
    instance = instance_double('Bosh::AwsCloud::Instance')
    allow(instance_manager).to receive(:find).with('fake-id').and_return(instance)

    expect(instance).to receive(:terminate).with(false)

    cloud.delete_vm('fake-id')
  end
end
