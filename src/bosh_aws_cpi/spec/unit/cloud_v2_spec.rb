require 'spec_helper'

describe Bosh::AwsCloud::CloudV2 do
  subject(:cloud) { described_class.new(cpi_version, options) }

  let(:cpi_version) { 2 }
  let(:options) { mock_cloud_options['properties'] }

  let(:az_selector) { instance_double(Bosh::AwsCloud::AvailabilityZoneSelector) }

  before do
    allow(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(az_selector)
    allow_any_instance_of(Aws::EC2::Resource).to receive(:subnets).and_return([double('subnet')])
  end

  describe '#initialize' do
    describe 'validating initialization options' do
      context 'when required options are missing' do
        let(:options) do
          {
            'plugin' => 'aws',
            'properties' => {}
          }
        end

        it 'raises an error' do
          expect { cloud }.to raise_error(
                                ArgumentError,
                                'missing configuration parameters > aws:default_key_name, aws:max_retries, registry:endpoint, registry:user, registry:password'
                              )
        end
      end

      context 'when both region or endpoints are missing' do
        let(:options) do
          opts = mock_cloud_options['properties']
          opts['aws'].delete('region')
          opts['aws'].delete('ec2_endpoint')
          opts['aws'].delete('elb_endpoint')
          opts
        end
        it 'raises an error' do
          expect { cloud }.to raise_error(
                                ArgumentError,
                                'missing configuration parameters > aws:region, or aws:ec2_endpoint and aws:elb_endpoint'
                              )
        end
      end

      context 'when all the required configurations are present' do
        it 'does not raise an error ' do
          expect { cloud }.to_not raise_error
        end
      end

      context 'when optional and required properties are provided' do
        let(:options) do
          mock_cloud_properties_merge(
            'aws' => {
              'region' => 'fake-region'
            }
          )
        end

        it 'passes required properties to AWS SDK' do
          config = cloud.aws_cloud.ec2_resource.client.config
          expect(config.region).to eq('fake-region')
        end
      end
    end
  end

  describe 'validating credentials_source' do
    context 'when credentials_source is set to static' do

      context 'when access_key_id and secret_access_key are omitted' do
        let(:options) do
          mock_cloud_properties_merge(
            'aws' => {
              'credentials_source' => 'static',
              'access_key_id' => nil,
              'secret_access_key' => nil
            }
          )
        end
        it 'raises an error' do
          expect { cloud }.to raise_error(
                                ArgumentError,
                                'Must use access_key_id and secret_access_key with static credentials_source'
                              )
        end
      end
    end

    context 'when credentials_source is set to env_or_profile' do
      let(:options) do
        mock_cloud_properties_merge(
          'aws' => {
            'credentials_source' => 'env_or_profile',
            'access_key_id' => nil,
            'secret_access_key' => nil
          }
        )
      end

      before(:each) do
        allow(Aws::InstanceProfileCredentials).to receive(:new).and_return(double(Aws::InstanceProfileCredentials))
      end

      it 'does not raise an error ' do
        expect { cloud }.to_not raise_error
      end
    end

    context 'when credentials_source is set to env_or_profile and access_key_id is provided' do
      let(:options) do
        mock_cloud_properties_merge(
          'aws' => {
            'credentials_source' => 'env_or_profile',
            'access_key_id' => 'some access key'
          }
        )
      end
      it 'raises an error' do
        expect { cloud }.to raise_error(
                              ArgumentError,
                              "Can't use access_key_id and secret_access_key with env_or_profile credentials_source"
                            )
      end
    end

    context 'when an unknown credentials_source is set' do
      let(:options) do
        mock_cloud_properties_merge(
          'aws' => {
            'credentials_source' => 'NotACredentialsSource'
          }
        )
      end

      it 'raises an error' do
        expect { cloud }.to raise_error(
                              ArgumentError,
                              'Unknown credentials_source NotACredentialsSource'
                            )
      end
    end
  end

  describe '#configure_networks' do
    it 'raises a NotSupported exception' do
      expect {
        cloud.configure_networks('i-foobar', {})
      }.to raise_error Bosh::Clouds::NotSupported
    end
  end

  describe '#info' do
    it 'returns correct info' do
      expect(cloud.info).to eq({'stemcell_formats' => ['aws-raw', 'aws-light'], 'api_version' => cpi_version})
    end
  end

  describe '#create_vm' do
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
    it 'should create an EC2 instance and return its id' do
      allow(Bosh::AwsCloud::ResourceWait).to receive(:for_instance).with(instance: instance, state: :running)
      expect(cloud.create_vm(agent_id, stemcell_id, vm_type, networks_spec, disk_locality, environment)).to eq({"vm_cid"=>"fake-id"})
    end
  end

  describe '#attach_disk' do
    let(:instance_id){ 'i-test' }
    let(:volume_id) { 'v-foobar' }
    let(:device_name) { '/dev/sdf' }
    let(:instance) { instance_double(Aws::EC2::Instance, :id => instance_id ) }
    let(:volume) { instance_double(Aws::EC2::Volume, :id => volume_id) }
    let(:subnet) { instance_double(Aws::EC2::Subnet) }

    before do
      allow(cloud.aws_cloud).to receive(:registry).and_return(mock_registry)
      allow(cloud.aws_cloud.ec2_resource).to receive(:instance).with('i-test').and_return(instance)
      allow(cloud.aws_cloud.ec2_resource).to receive(:volume).with('v-foobar').and_return(volume)
      allow(cloud.aws_cloud.ec2_resource).to receive(:subnets).and_return([subnet])
      allow(instance).to receive(:block_device_mappings).and_return({})
    end

    it 'should attach an EC2 volume to an instance' do
      attachment = instance_double(Bosh::AwsCloud::SdkHelpers::VolumeAttachment, device: '/dev/sdf')

      fake_resp = double('attachment-resp')
      expect(volume).to receive(:attach_to_instance).
        with(instance_id: instance_id, device: device_name).and_return(fake_resp)

      allow(Bosh::AwsCloud::SdkHelpers::VolumeAttachment).to receive(:new).with(fake_resp, cloud.aws_cloud.ec2_resource).and_return(attachment)
      allow(Bosh::AwsCloud::ResourceWait).to receive(:for_attachment).with(attachment: attachment, state: 'attached')

      expect(cloud.aws_cloud.registry).to receive(:update_settings)
      expect(cloud.aws_cloud.registry).to receive(:read_settings).thrice.with('i-test').and_return({'funky'=> 'chicken'})

      expect(cloud.attach_disk(instance_id, volume_id, {})).to eq({'device_name'=>device_name})
    end
  end
end
