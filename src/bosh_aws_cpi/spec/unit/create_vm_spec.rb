require 'spec_helper'


describe Bosh::AwsCloud::CloudCore, 'create_vm' do
  subject(:cloud) { described_class.new(config, logger, volume_manager, az_selector) }
  let(:ec2) {mock_ec2}

  let(:volume_manager) {instance_double(Bosh::AwsCloud::VolumeManager)}
  let(:az_selector) {instance_double(Bosh::AwsCloud::AvailabilityZoneSelector)}
  let(:api_version) {2}
  let(:logger) {Bosh::Clouds::Config.logger}
  let(:options) {mock_cloud_options['properties']}
  let(:validate_registry) {true}
  let(:config) {Bosh::AwsCloud::Config.build(options, validate_registry)}
  let(:az_selector) {instance_double(Bosh::AwsCloud::AvailabilityZoneSelector)}

  let(:global_config) {instance_double(Bosh::AwsCloud::Config, aws: Bosh::AwsCloud::AwsConfig.new({}))}
  let(:props_factory) {instance_double(Bosh::AwsCloud::PropsFactory)}
  let(:vm_cloud_props) {Bosh::AwsCloud::VMCloudProps.new({}, global_config)}
  let(:networks_cloud_props) {Bosh::AwsCloud::NetworkCloudProps.new(networks_spec, global_config)}
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
  let(:agent_id) {'007-agent'}
  let(:instance_id) {'instance-id'}
  let(:environment) {{}}

  let(:stemcell) {instance_double(Bosh::AwsCloud::Stemcell, root_device_name: 'root name', image_id: stemcell_id)}
  let(:stemcell_id) {'stemcell-id'}

  let(:vm_type) {'vm-type'}
  let(:disk_locality) {[]}
  let(:user_data) {Base64.encode64('user-data').strip}

  let(:temp_snapshot) {nil}

  let(:block_device_manager) {instance_double(Bosh::AwsCloud::BlockDeviceManager)}
  let(:mappings) {['some-mapping']}
  let(:block_device_agent_info) do
    {
      'ephemeral' => [{'path' => '/dev/sdz'}],
      'raw_ephemeral' => [{'path' => '/dev/xvdba'}, {'path' => '/dev/xvdbb'}]
    }
  end

  let(:instance_manager) {instance_double(Bosh::AwsCloud::InstanceManager)}
  let(:instance) {instance_double(Bosh::AwsCloud::Instance, id: 'fake-id')}
  let(:network_configurator) {instance_double(Bosh::AwsCloud::NetworkConfigurator)}

  let(:agent_settings) {instance_double(Bosh::AwsCloud::AgentSettings).as_null_object}

  before do
    allow(Bosh::AwsCloud::InstanceManager).to receive(:new).and_return(instance_manager)
    allow(instance_manager).to receive(:create).and_return(instance)

    allow(Bosh::AwsCloud::BlockDeviceManager).to receive(:new).and_return(block_device_manager)
    allow(block_device_manager).to receive(:mappings_and_info).and_return([mappings, block_device_agent_info])

    allow(Bosh::AwsCloud::PropsFactory).to receive(:new).and_return(props_factory)
    allow(props_factory).to receive(:vm_props).with(vm_type).and_return(vm_cloud_props)
    allow(props_factory).to receive(:network_props).with(networks_spec).and_return(networks_cloud_props)

    allow(Aws::EC2::Resource).to receive(:new).and_return(ec2)
    allow(ec2).to receive(:subnets).and_return([double('subnet')])

    allow(Bosh::AwsCloud::Stemcell).to receive(:find).with(ec2, stemcell_id).and_return(stemcell)
    allow(Bosh::AwsCloud::NetworkConfigurator).to receive(:new).with(networks_cloud_props).and_return(network_configurator)
    allow(network_configurator).to receive(:configure)
  end

  context 'when the yielded method raises an error' do
    it 'terminates the instance' do
      expect(instance).to receive(:terminate)

      expect do
        cloud.create_vm(agent_id, stemcell_id, vm_type, networks_cloud_props, agent_settings, disk_locality, environment) do
          raise 'CreateVM runtime error'
        end
      end.to raise_error RuntimeError, /CreateVM runtime error/
    end
  end

  it 'passes the image_id of the stemcell to an InstanceManager in order to create a VM' do
    expect(stemcell).to receive(:image_id).with(no_args).and_return('ami-1234')
    expect(instance_manager).to receive(:create).with(
      'ami-1234',
      anything,
      anything,
      anything,
      anything,
      anything,
      anything
    ).and_return(instance)
    expect(cloud.create_vm(agent_id, stemcell_id, vm_type, networks_cloud_props, agent_settings, disk_locality, environment)).to eq(['fake-id', block_device_agent_info])
  end

  it 'should create an EC2 instance and return its id' do
    allow(Bosh::AwsCloud::ResourceWait).to receive(:for_instance).with(instance: instance, state: :running)
    expect(cloud.create_vm(agent_id, stemcell_id, vm_type, networks_cloud_props, agent_settings, disk_locality, environment)).to eq(['fake-id', block_device_agent_info])
  end

  it 'should configure the IP for the created instance according to the network specifications' do
    allow(Bosh::AwsCloud::ResourceWait).to receive(:for_instance).with(instance: instance, state: :running)
    expect(network_configurator).to receive(:configure).with(ec2, instance)
    cloud.create_vm(agent_id, stemcell_id, vm_type, networks_cloud_props, agent_settings, disk_locality, environment)
  end

  context 'when specifying kms encryption for ephemeral device' do
    let(:encrypted_temp_disk_configuration) {{'encrypted' => true, 'kms_key_arn' => 'some-kms-key'}}
    let(:vm_type) do
      {
        'instance_type' => 'm1.small',
        'availability_zone' => 'us-east-1a',
        'ephemeral_disk' => encrypted_temp_disk_configuration
      }
    end
    let(:temp_volume) {instance_double(Aws::EC2::Volume)}
    let(:temp_snapshot) {instance_double(Aws::EC2::Snapshot, id: 's-id')}
    let(:vm_cloud_props) do
      Bosh::AwsCloud::VMCloudProps.new({'ephemeral_disk' => {'encrypted' => true, 'kms_key_arn' => 'some-kms-key'}}, global_config)
    end

    before do
      allow(Bosh::AwsCloud::ResourceWait).to receive(:for_snapshot).with(snapshot: temp_snapshot, state: 'completed')
      allow(agent_settings).to receive(:encode).and_return('my-encoded-value')
    end

    it 'creates and deletes an encrypted volume and snapshot and sends the snapshot to block device manager' do
      expect(volume_manager).to receive(:create_ebs_volume).with(hash_including({
                                                                                  encrypted: true,
                                                                                  kms_key_id: 'some-kms-key',
                                                                                  tag_specifications: [{
                                                                                                         resource_type: 'volume',
                                                                                                         tags: [{key: 'ephemeral_disk_agent_id', value: "temp-vol-bosh-agent-#{agent_id}"}]
                                                                                                       }]
                                                                                })).and_return temp_volume
      expect(temp_volume).to receive(:create_snapshot).and_return temp_snapshot
      expect(temp_snapshot).to receive(:create_tags).with({tags: [{key: "ephemeral_disk_agent_id", value: "temp-snapshot-bosh-agent-#{agent_id}"}]})

      expect(temp_snapshot).to receive(:delete)
      expect(volume_manager).to receive(:delete_ebs_volume).with temp_volume

      expect(instance_manager).to receive(:create).with(
        stemcell_id,
        vm_cloud_props,
        networks_cloud_props,
        disk_locality,
        [],
        mappings,
        'my-encoded-value'
      )

      cloud.create_vm(agent_id, stemcell_id, vm_type, networks_cloud_props, agent_settings, disk_locality, environment)
    end
  end
end
