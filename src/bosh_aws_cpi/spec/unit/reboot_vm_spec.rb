require 'spec_helper'

describe Bosh::AwsCloud::CloudV1, "reboot_vm" do
  let(:cloud) { mock_cloud }

  it 'deletes an EC2 instance' do
    instance_manager = instance_double('Bosh::AwsCloud::InstanceManager')
    allow(Bosh::AwsCloud::InstanceManager).to receive(:new).and_return(instance_manager)

    instance = instance_double('Bosh::AwsCloud::Instance')
    allow(instance_manager).to receive(:find).with('fake-id').and_return(instance)

    expect(instance).to receive(:reboot).with(no_args)
    cloud.reboot_vm('fake-id')
  end
end
