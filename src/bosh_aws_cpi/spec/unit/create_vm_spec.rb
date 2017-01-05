require "spec_helper"

describe Bosh::AwsCloud::Cloud, "create_vm" do
  let(:registry) { double("registry") }
  let(:availability_zone_selector) { double("availability zone selector") }
  let(:stemcell) { double("stemcell", root_device_name: "root name", image_id: stemcell_id) }
  let(:instance_manager) { instance_double("Bosh::AwsCloud::InstanceManager") }
  let (:block_device_agent_info) {
    {
        "ephemeral" => [{"path" => "/dev/sdz"}],
        "raw_ephemeral" => [{"path" => "/dev/xvdba"}, {"path" => "/dev/xvdbb"}],
    }
  }
  let(:instance) { instance_double("Bosh::AwsCloud::Instance", id: "fake-id") }
  let(:network_configurator) { double("network configurator") }

  let(:agent_id) { "agent_id" }
  let(:stemcell_id) { "stemcell_id" }
  let(:vm_type) { {} }
  let(:networks_spec) do
    {
      "fake-network-name-1" => {
        "type" => "dynamic",
      },
      "fake-network-name-2" => {
        "type" => "manual",
      }
    }
  end
  let(:disk_locality) { double("disk locality") }
  let(:environment) { "environment" }

  let(:options) do
    ops = mock_cloud_properties_merge({
      "aws" => {
          "region" => "bar",
      }
    })

    ops['agent'] = {
        "baz" => "qux"
    }

    ops
  end

  before do
    @cloud = mock_cloud(options) do |_ec2|
      @ec2 = _ec2

      allow(Bosh::Cpi::RegistryClient).to receive(:new).and_return(registry)

      allow(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).
          with(@ec2).
          and_return(availability_zone_selector)

      allow(Bosh::AwsCloud::Stemcell).to receive(:find).with(@ec2, stemcell_id).and_return(stemcell)

      allow(Aws::ElasticLoadBalancing).to receive(:new).with(hash_including(region: 'bar'))

      allow(Bosh::AwsCloud::InstanceManager).to receive(:new).and_return(instance_manager)
    end

    allow(instance_manager).to receive(:create).
      with(agent_id, stemcell_id, vm_type, networks_spec, disk_locality, environment, options).
      and_return([instance, block_device_agent_info])

    allow(Bosh::AwsCloud::NetworkConfigurator).to receive(:new).
      with(networks_spec).
      and_return(network_configurator)

    allow(vm_type).to receive(:[]).and_return(false)
    allow(network_configurator).to receive(:configure)
    allow(registry).to receive(:update_settings)
  end

  it 'passes the image_id of the stemcell to an InstanceManager in order to create a VM' do
    expect(stemcell).to receive(:image_id).with(no_args).and_return('ami-1234')
    expect(instance_manager).to receive(:create).with(
      anything,
      'ami-1234',
      anything,
      anything,
      anything,
      anything,
      anything,
    ).and_return([instance, block_device_agent_info])
    expect(@cloud.create_vm(agent_id, stemcell_id, vm_type, networks_spec, disk_locality, environment)).to eq("fake-id")
  end

  it "should create an EC2 instance and return its id" do
    allow(Bosh::AwsCloud::ResourceWait).to receive(:for_instance).with(instance: instance, state: :running)
    expect(@cloud.create_vm(agent_id, stemcell_id, vm_type, networks_spec, disk_locality, environment)).to eq("fake-id")
  end

  it "should configure the IP for the created instance according to the network specifications" do
    allow(Bosh::AwsCloud::ResourceWait).to receive(:for_instance).with(instance: instance, state: :running)
    expect(network_configurator).to receive(:configure).with(@ec2, instance)
    @cloud.create_vm(agent_id, stemcell_id, vm_type, networks_spec, disk_locality, environment)
  end

  it "should update the registry settings with the new instance" do
    allow(Bosh::AwsCloud::ResourceWait).to receive(:for_instance).with(instance: instance, state: :running)
    allow(SecureRandom).to receive(:uuid).and_return("rand0m")

    agent_settings = {
        "vm" => {
            "name" => "vm-rand0m"
        },
        "agent_id" => agent_id,
        "networks" =>     {
          "fake-network-name-1" => {
            "type" => "dynamic",
            "use_dhcp" => true,
          },
          "fake-network-name-2" => {
            "type" => "manual",
            "use_dhcp" => true,
          }
        },
        "disks" => {
            "system" => "root name",
            "ephemeral" => "/dev/sdz",
            "raw_ephemeral" => [{"path" => "/dev/xvdba"}, {"path" => "/dev/xvdbb"}],
            "persistent" => {}
        },
        "env" => environment,
        "baz" => "qux"
    }
    expect(registry).to receive(:update_settings).with("fake-id", agent_settings)

    @cloud.create_vm(agent_id, stemcell_id, vm_type, networks_spec, disk_locality, environment)
  end

  it 'terminates instance if updating registry settings fails' do
    allow(network_configurator).to receive(:configure).and_raise(StandardError)
    expect(instance).to receive(:terminate)

    expect {
      @cloud.create_vm(agent_id, stemcell_id, vm_type, networks_spec, disk_locality, environment)
    }.to raise_error(StandardError)
  end

  it 'terminates instance if updating registry settings fails' do
    allow(registry).to receive(:update_settings).and_raise(StandardError)
    expect(instance).to receive(:terminate)

    expect {
      @cloud.create_vm(agent_id, stemcell_id, vm_type, networks_spec, disk_locality, environment)
    }.to raise_error(StandardError)
  end

  it 'creates elb client with correct region' do

    @cloud.create_vm(agent_id, stemcell_id, vm_type, networks_spec, disk_locality, environment)
  end
end
