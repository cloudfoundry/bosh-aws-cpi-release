require 'spec_helper'

describe Bosh::AwsCloud::Cloud, "reboot_vm" do
  let(:cloud) { described_class.new(options) }
  let(:ec2) { double("ec2", regions: [ double("region") ]) }
  let(:options) { mock_cloud_options['properties'] }

  it 'deletes an EC2 instance' do
    registry = double("registry")
    allow(Bosh::Cpi::RegistryClient).to receive(:new).and_return(registry)

    allow(Aws::EC2::Resource).to receive(:new).and_return(ec2)
    allow(ec2).to receive(:subnets).and_return([double('subnet')])

    az_selector = double("availability zone selector")
    allow(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).
      with(ec2).
      and_return(az_selector)

    instance_manager = instance_double('Bosh::AwsCloud::InstanceManager')
    allow(Bosh::AwsCloud::InstanceManager).to receive(:new).
      with(
        ec2,
        registry,
        be_an_instance_of(Aws::ElasticLoadBalancing::Client),
        be_an_instance_of(Bosh::AwsCloud::InstanceParamMapper),
        be_an_instance_of(Bosh::AwsCloud::BlockDeviceManager),
        be_an_instance_of(Logger)
      ).and_return(instance_manager)

    instance = instance_double('Bosh::AwsCloud::Instance')
    allow(instance_manager).to receive(:find).with('fake-id').and_return(instance)

    expect(instance).to receive(:reboot).with(no_args)

    cloud.reboot_vm('fake-id')
  end
end
