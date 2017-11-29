require 'spec_helper'

describe Bosh::AwsCloud::Cloud, 'create_vm' do
  let(:registry) { instance_double(Bosh::Cpi::RegistryClient) }
  let(:availability_zone_selector) { instance_double(Bosh::AwsCloud::AvailabilityZoneSelector) }
  let(:stemcell) { instance_double(Bosh::AwsCloud::Stemcell, root_device_name: 'root name', image_id: stemcell_id) }
  let(:instance_manager) { instance_double(Bosh::AwsCloud::InstanceManager) }
  let(:block_device_manager) { instance_double(Bosh::AwsCloud::BlockDeviceManager) }
  let(:block_device_agent_info) do
    {
      'ephemeral' => [{ 'path' => '/dev/sdz' }],
      'raw_ephemeral' => [{ 'path' => '/dev/xvdba' }, { 'path' => '/dev/xvdbb' }]
    }
  end
  let(:mappings) { ['some-mapping'] }
  let(:instance) { instance_double(Bosh::AwsCloud::Instance, id: 'fake-id') }
  let(:network_configurator) { instance_double(Bosh::AwsCloud::NetworkConfigurator) }
  let(:global_config) { instance_double(Bosh::AwsCloud::Config, aws: Bosh::AwsCloud::AwsConfig.new({})) }
  let(:agent_id) {'agent_id'}
  let(:stemcell_id) {'stemcell_id'}
  let(:vm_type) { {} }
  let(:vm_cloud_props) do
    Bosh::AwsCloud::VMCloudProps.new({}, global_config)
  end
  let(:networks_spec) do
    {
      'fake-network-name-1' => {
        'type' => 'dynamic'
      },
      'fake-network-name-2' => {
        'type' => 'manual'
      }
    }
  end
  let(:networks_cloud_props) do
    Bosh::AwsCloud::NetworkCloudProps.new(networks_spec, global_config)
  end
  let(:networks_cloud_props) do
    Bosh::AwsCloud::NetworkCloudProps.new(networks_spec, global_config)
  end
  let(:disk_locality) { ['some', 'disk', 'locality'] }
  let(:environment) { 'environment' }
  let(:options) do
    ops = mock_cloud_properties_merge(
      'aws' => {
        'region' => 'bar'
      }
    )
    ops['agent'] = {
      'baz' => 'qux'
    }
    ops
  end
  let(:props_factory) { instance_double(Bosh::AwsCloud::PropsFactory) }
  let(:volume_manager) { instance_double(Bosh::AwsCloud::VolumeManager) }
  let(:temp_snapshot) { nil }

  before do
    @cloud = mock_cloud(options) do |_ec2|
      @ec2 = _ec2

      allow(Bosh::Cpi::RegistryClient).to receive(:new).and_return(registry)

      allow(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new)
        .with(@ec2)
        .and_return(availability_zone_selector)

      allow(Bosh::AwsCloud::Stemcell).to receive(:find).with(@ec2, stemcell_id).and_return(stemcell)

      allow(Bosh::AwsCloud::InstanceManager).to receive(:new).and_return(instance_manager)

      allow(Bosh::AwsCloud::PropsFactory).to receive(:new).and_return(props_factory)

      allow(Bosh::AwsCloud::VolumeManager).to receive(:new).with(anything, anything).and_return(volume_manager)
    end

    allow(props_factory).to receive(:vm_props).with(vm_type).and_return(vm_cloud_props)
    allow(props_factory).to receive(:network_props).with(networks_spec).and_return(networks_cloud_props)

    allow(instance_manager).to receive(:create)
      .with(stemcell_id, vm_cloud_props, networks_cloud_props, disk_locality, [], mappings)
      .and_return(instance)

    allow(Bosh::AwsCloud::NetworkConfigurator).to receive(:new).with(networks_cloud_props).and_return(network_configurator)
    allow(Bosh::AwsCloud::BlockDeviceManager).to receive(:new)
      .with(anything, stemcell, vm_cloud_props, temp_snapshot)
      .and_return(block_device_manager)

    allow(block_device_manager).to receive(:mappings_and_info).and_return([mappings, block_device_agent_info])

    allow(vm_type).to receive(:[]).and_return(false)
    allow(network_configurator).to receive(:configure)
    allow(registry).to receive(:update_settings)
  end

  it 'passes the image_id of the stemcell to an InstanceManager in order to create a VM' do
    expect(stemcell).to receive(:image_id).with(no_args).and_return('ami-1234')
    expect(instance_manager).to receive(:create).with(
      'ami-1234',
      anything,
      anything,
      anything,
      anything,
      anything
    ).and_return(instance)
    expect(@cloud.create_vm(agent_id, stemcell_id, vm_type, networks_spec, disk_locality, environment)).to eq('fake-id')
  end

  it 'should create an EC2 instance and return its id' do
    allow(Bosh::AwsCloud::ResourceWait).to receive(:for_instance).with(instance: instance, state: :running)
    expect(@cloud.create_vm(agent_id, stemcell_id, vm_type, networks_spec, disk_locality, environment)).to eq('fake-id')
  end

  it 'should configure the IP for the created instance according to the network specifications' do
    allow(Bosh::AwsCloud::ResourceWait).to receive(:for_instance).with(instance: instance, state: :running)
    expect(network_configurator).to receive(:configure).with(@ec2, instance)
    @cloud.create_vm(agent_id, stemcell_id, vm_type, networks_spec, disk_locality, environment)
  end

  it 'should update the registry settings with the new instance' do
    allow(Bosh::AwsCloud::ResourceWait).to receive(:for_instance).with(instance: instance, state: :running)
    allow(SecureRandom).to receive(:uuid).and_return('rand0m')

    agent_settings = {
        'vm' => {
            'name' => 'vm-rand0m'
        },
        'agent_id' => agent_id,
        'networks' =>     {
            'fake-network-name-1' => {
                'type' => 'dynamic',
                'use_dhcp' => true,
          },
            'fake-network-name-2' => {
              'type' => 'manual',
              'use_dhcp' => true,
          }
        },
        'disks' => {
            'system' => 'root name',
            'ephemeral' => '/dev/sdz',
            'raw_ephemeral' => [{'path' => '/dev/xvdba'}, {'path' => '/dev/xvdbb'}],
            'persistent' => {}
        },
        'env' => environment,
        'baz' => 'qux'
    }
    expect(registry).to receive(:update_settings).with('fake-id', agent_settings)

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

  context 'when specifying kms encryption for ephemeral device' do
    let(:encrypted_temp_disk_configuration) { {'encrypted' => true, 'kms_key_arn' => 'some-kms-key'} }
    let(:vm_type) do
      {
        'instance_type' => 'm1.small',
        'availability_zone' => 'us-east-1a',
        'ephemeral_disk' => encrypted_temp_disk_configuration
      }
    end
    let(:temp_volume) { instance_double(Aws::EC2::Volume) }
    let(:temp_snapshot) { instance_double(Aws::EC2::Snapshot, id: 's-id') }
    let(:vm_cloud_props) do
      Bosh::AwsCloud::VMCloudProps.new({'ephemeral_disk' => {'encrypted' => true, 'kms_key_arn' => 'some-kms-key'}}, global_config)
    end

    before do
      allow(Bosh::AwsCloud::ResourceWait).to receive(:for_snapshot).with(snapshot: temp_snapshot, state: 'completed')
    end

    it 'creates and deletes an encrypted volume and snapshot and sends the snapshot to block device manager' do
      expect(volume_manager).to receive(:create_ebs_volume).with(hash_including({
        encrypted: true, kms_key_id: 'some-kms-key'
      })).and_return temp_volume
      expect(temp_volume).to receive(:create_snapshot).and_return temp_snapshot

      expect(temp_snapshot).to receive(:delete)
      expect(volume_manager).to receive(:delete_ebs_volume).with temp_volume

      expect(instance_manager).to receive(:create).with(
        stemcell_id,
        vm_cloud_props,
        networks_cloud_props,
        disk_locality,
        [],
        mappings
      )

      @cloud.create_vm(agent_id, stemcell_id, vm_type, networks_spec, disk_locality, environment)
    end
  end
end
