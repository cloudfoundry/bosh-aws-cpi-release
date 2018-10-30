require 'spec_helper'

describe Bosh::AwsCloud::CloudV1 do
  subject(:cloud) { described_class.new(options) }

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
              'missing configuration parameters > aws:default_key_name, aws:max_retries'
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
          config = cloud.ec2_resource.client.config
          expect(config.region).to eq('fake-region')
        end
      end

      context 'when registry settings are not present' do
        before(:each) do
          options.delete('registry')
        end

        it 'should use a disabled registry client' do
          expect(Bosh::AwsCloud::RegistryDisabledClient).to receive(:new)
          expect(Bosh::Cpi::RegistryClient).to_not receive(:new)
          expect { cloud }.to_not raise_error
        end
      end

    end
  end

  describe '#create_disk' do
    let(:cloud_properties) { {} }
    let(:volume) { instance_double(Aws::EC2::Volume, id: 'fake-volume-id') }

    before do
      allow(az_selector).to receive(:select_availability_zone).
        with(42).and_return('fake-availability-zone')
    end

    before do
      allow(Bosh::AwsCloud::ResourceWait).to receive(:for_volume).with(volume: volume, state: 'available')
    end

    context 'when volumes are set' do
      let(:ec2_client) { instance_double(Aws::EC2::Client) }
      let(:volume_resp) { instance_double(Aws::EC2::Types::Volume, volume_id: 'fake-volume-id') }
      let(:volume) { instance_double(Aws::EC2::Volume, id: 'fake-volume-id') }
      let(:volume_manager) { instance_double(Bosh::AwsCloud::VolumeManager) }
      before do
        # cloud.instance_variable_set(:@ec2_client, ec2_client)
        volume_manager = cloud.instance_variable_get(:@volume_manager)
        volume_manager.instance_variable_set(:@ec2_client, ec2_client)
      end

      context 'when disk type is provided' do
        let(:cloud_properties) { { 'type' => disk_type } }

        context 'when disk size is between 1 GiB and 16 TiB' do
          let(:disk_size) { 10240000 }

          context 'when disk type is gp2' do
            let(:disk_type) { 'gp2' }

            it 'creates disk with gp2 type' do
              expect(ec2_client).to receive(:create_volume).with(
                size: 10000,
                availability_zone: 'fake-availability-zone',
                volume_type: 'gp2',
                encrypted: false
              ).and_return(volume_resp)

              allow(Aws::EC2::Volume).to receive(:new).with(
                id: 'fake-volume-id',
                client: ec2_client,
              ).and_return(volume)
              cloud.create_disk(disk_size, cloud_properties, 42)
            end
          end

          context 'when disk type is io1' do
            let(:cloud_properties) { { 'type' => disk_type, 'iops' => 123 } }
            let(:disk_type) { 'io1' }

            it 'creates disk with io1 type' do
              expect(ec2_client).to receive(:create_volume).with(
                size: 10000,
                availability_zone: 'fake-availability-zone',
                volume_type: 'io1',
                iops: 123,
                encrypted: false
              ).and_return(volume_resp)

              allow(Aws::EC2::Volume).to receive(:new).with(
                id: 'fake-volume-id',
                client: ec2_client,
              ).and_return(volume)

              cloud.create_disk(disk_size, cloud_properties, 42)
            end
          end
        end

        context 'when disk size is between 1 GiB and 1 TiB' do
          let(:disk_size) { 1025 }

          context 'when disk type is specified' do
            let(:disk_type) { 'standard' }

            it 'creates disk with the specified type' do
              expect(ec2_client).to receive(:create_volume).with(
                size: 2,
                availability_zone: 'fake-availability-zone',
                volume_type: 'standard',
                encrypted: false
              ).and_return(volume_resp)

              allow(Aws::EC2::Volume).to receive(:new).with(
                id: 'fake-volume-id',
                client: ec2_client,
              ).and_return(volume)

              cloud.create_disk(disk_size, cloud_properties, 42)
            end
          end
        end
      end

      context 'when disk type is not provided' do
        let(:cloud_properties) { {} }
        let(:disk_size) { 1025 }

        it 'creates disk with gp2 disk type' do
          expect(ec2_client).to receive(:create_volume).with(
            size: 2,
            availability_zone: 'fake-availability-zone',
            volume_type: 'gp2',
            encrypted: false
          ).and_return(volume_resp)

          allow(Aws::EC2::Volume).to receive(:new).with(
            id: 'fake-volume-id',
            client: ec2_client,
          ).and_return(volume)

          cloud.create_disk(disk_size, cloud_properties, 42)
        end
      end
    end
  end

  describe '#info' do
    let(:volume_manager) { instance_double(Bosh::AwsCloud::VolumeManager) }
    let(:az_selector) { instance_double(Bosh::AwsCloud::AvailabilityZoneSelector) }
    let(:api_version) { 2 }
    let(:options) { mock_cloud_options['properties'] }
    let(:config) { Bosh::AwsCloud::Config.build(options, validate_registry) }
    let(:logger) { Bosh::Clouds::Config.logger }
    let(:cloud_core) { Bosh::AwsCloud::CloudCore.new(config, logger, volume_manager, az_selector, api_version) }

    it 'returns correct info with default api_version' do
      expect(cloud.info).to eq({'stemcell_formats' => ['aws-raw', 'aws-light'], 'api_version' => api_version})
    end

    context 'when api_version is specified in config json' do
      let(:options) do
        mock_cloud_properties_merge(
          'api_version' => 42
        )
      end

      let(:config) { Bosh::AwsCloud::Config.build(options) }
      let(:cloud_core) { Bosh::AwsCloud::CloudCore.new(config, logger, volume_manager, az_selector, api_version) }

      it 'returns correct api_version in info' do
        expect(cloud.info).to eq({'stemcell_formats' => ['aws-raw', 'aws-light'], 'api_version' => api_version})
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

  describe '#create_vm' do
    let(:registry) { instance_double(Bosh::Cpi::RegistryClient) }

    let(:global_config) { instance_double(Bosh::AwsCloud::Config, aws: Bosh::AwsCloud::AwsConfig.new({})) }
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
    let(:environment) { {} }
    let(:agent_id) { '007-agent' }
    let(:instance_id) { 'instance-id' }
    let(:root_device_name) { 'root name' }
    let(:agent_info) do
      {
        'ephemeral' => [{'path' => '/dev/sdz'}],
        'raw_ephemeral' => [{'path'=>'/dev/xvdba'}, {'path'=>'/dev/xvdbb'}]
      }
    end
    let(:agent_config) { {'baz' => 'qux'} }

    let(:stemcell_id) { 'stemcell-id' }
    let(:vm_type) { 'vm-type' }
    let(:disk_locality) { [] }
    let(:cloud_core) { instance_double(Bosh::AwsCloud::CloudCore) }
    let(:agent_settings_double) {instance_double(Bosh::AwsCloud::AgentSettings)}

    before do
      allow(Bosh::Cpi::RegistryClient).to receive(:new).and_return(registry)
      allow(registry).to receive(:endpoint).and_return('http://something.12.34.52')
      allow(SecureRandom).to receive(:uuid).and_return('rand0m')

      allow(Bosh::AwsCloud::CloudCore).to receive(:new).and_return(cloud_core)
    end

    it 'updates the registry' do
      agent_settings = {
        'vm' => {
          'name' => 'vm-rand0m'
        },
        'agent_id' => agent_id,
        'networks' => {
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

      allow(agent_settings_double).to receive(:agent_settings).and_return(agent_settings)
      allow(cloud_core).to receive(:create_vm).and_yield(instance_id, agent_settings_double)
      expect(registry).to receive(:update_settings).with(instance_id, agent_settings)

      cloud.create_vm(agent_id, stemcell_id, vm_type, networks_spec, disk_locality, environment)
    end

    context 'when registry is not configured' do
      before do
        options.delete('registry')
      end

      it 'raises an error' do
        expect {
          cloud.create_vm(agent_id, stemcell_id, vm_type, networks_spec, disk_locality, environment)
        }.to raise_error(/Cannot create VM without registry with CPI v1. Registry not configured./)
      end
    end
  end
end
