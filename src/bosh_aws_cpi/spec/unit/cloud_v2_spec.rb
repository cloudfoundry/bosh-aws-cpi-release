require 'spec_helper'

describe Bosh::AwsCloud::CloudV2 do
  subject(:cloud) { described_class.new(options) }

  let(:cloud_core) { instance_double(Bosh::AwsCloud::CloudCore) }
  let(:options) { mock_cloud_options['properties'] }
  let(:az_selector) { instance_double(Bosh::AwsCloud::AvailabilityZoneSelector) }
  let(:registry) { instance_double(Bosh::Cpi::RegistryClient) }
  let(:endpoint) {'http://registry:3333'}

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
          config = cloud.ec2_resource.client.config
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
      expect(cloud.info).to eq({'stemcell_formats' => ['aws-raw', 'aws-light'], 'api_version' => 2})
    end
  end

  describe '#create_vm' do
    let(:instance) { instance_double(Bosh::AwsCloud::Instance, id: 'fake-id') }
    let(:agent_id) {'agent_id'}
    let(:stemcell_id) {'stemcell_id'}
    let(:vm_type) { {} }
    let(:instance_id) {'instance-id'}

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

    let(:disk_locality) { ['some', 'disk', 'locality'] }
    let(:environment) { 'environment' }
    let(:agent_settings_double) { instance_double(Bosh::AwsCloud::AgentSettings)}
    let(:registry) { instance_double(Bosh::Cpi::RegistryClient) }
    let(:agent_settings) do
      {
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
    end

    before do
      allow(agent_settings_double).to receive(:agent_settings).and_return(agent_settings)
      allow(registry).to receive(:update_settings)
      allow(registry).to receive(:endpoint).and_return('http://something.12.34.52')
      allow(Bosh::Cpi::RegistryClient).to receive(:new).and_return(registry)
      allow(Bosh::AwsCloud::CloudCore).to receive(:new).and_return(cloud_core)
      allow(cloud_core).to receive(:create_vm).and_return([instance.id, "anything"]).and_yield(instance_id, agent_settings_double)
    end

    it 'should create an EC2 instance and return its id and disk hints' do
      expect(cloud.create_vm(agent_id, stemcell_id, vm_type, networks_spec, disk_locality, environment)).to eq([instance.id, networks_spec])
    end

    context 'when stemcell version is less than 2' do
      it 'updates the registry' do
        expect(registry).to receive(:update_settings).with(instance_id, agent_settings)
        cloud.create_vm(agent_id, stemcell_id, vm_type, networks_spec, disk_locality, environment)
      end
    end

    context 'when stemcell version is 2 or greater' do
      let(:options) do
        mock_cloud_properties_merge(
          {
            'aws' => {
              'vm' => {
                'stemcell' => {
                  'api_version' => 2
                }
              }
            }
          }
        )
      end

      it 'should NOT update the registry' do
        expect(registry).to_not receive(:update_settings)
        cloud.create_vm(agent_id, stemcell_id, vm_type, networks_spec, disk_locality, environment)
      end
    end
  end

  describe '#attach_disk' do
    let(:instance_id){ 'i-test' }
    let(:volume_id) { 'new-disk' }
    let(:device_name) { '/dev/sdg' }
    let(:settings) {
      {
        'foo' => 'bar',
        'disks' => {
          'persistent' => {
            'existing-disk' => '/dev/sdf'
          }
        }
      }
    }

    let(:expected_settings) {settings do |s| s['disk']['persistent'][volume_id] = device_name end}

    before do
      allow(registry).to receive(:update_settings)
      allow(registry).to receive(:read_settings).and_return(settings)
      allow(registry).to receive(:endpoint).and_return('http://something.12.34.52')
      allow(Bosh::Cpi::RegistryClient).to receive(:new).and_return(registry)

      allow(Bosh::AwsCloud::CloudCore).to receive(:new).and_return(cloud_core)
      allow(cloud_core).to receive(:attach_disk).and_return(device_name).and_yield(device_name)
    end

    context 'when stemcell version is less than 2' do
      it 'should update registry' do
        expect(registry).to receive(:update_settings).with(instance_id, expected_settings)
        expect(subject.attach_disk(instance_id, volume_id)).to eq(device_name)
      end
    end

    context 'when stemcell version is 2 or greater' do
      let(:options) do
        mock_cloud_properties_merge(
          {
            'aws' => {
              'vm' => {
                'stemcell' => {
                  'api_version' => 2
                }
              }
            }
          }
        )
      end
      it 'should NOT update registry' do
        expect(registry).to_not receive(:update_settings)
        expect(subject.attach_disk(instance_id, volume_id)).to eq(device_name)
      end
    end
  end

  describe '#delete_vm' do
    let(:instance_id){ 'i-test' }
    let(:registry) { instance_double(Bosh::Cpi::RegistryClient) }

    before do
      allow(cloud_core).to receive(:delete_vm).and_return(instance_id).and_yield(instance_id)
      allow(Bosh::Cpi::RegistryClient).to receive(:new).and_return(registry)
      allow(Bosh::AwsCloud::CloudCore).to receive(:new).and_return(cloud_core)
      allow(registry).to receive(:delete_settings)
    end

    it 'deletes the vm' do
      expect(cloud_core).to receive(:delete_vm).with(instance_id)
      expect(subject.delete_vm(instance_id)).to eq(instance_id)
    end

    context 'stemcell version is less than 2' do
      it 'should update the registry' do
        expect(registry).to receive(:delete_settings)
        subject.delete_vm(instance_id)
      end
    end

    context 'stemcell version is 2 or greater' do
      let(:options) do
        mock_cloud_properties_merge(
          {
            'aws' => {
              'vm' => {
                'stemcell' => {
                  'api_version' => 2
                }
              }
            }
          }
        )
      end

      it 'should not update the registry' do
        expect(registry).to_not receive(:delete_settings)
        subject.delete_vm(instance_id)
      end
    end
  end
end
