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
      expect(cloud.info).to eq({'stemcell_formats' => ['aws-raw', 'aws-light'], 'api_version' => cpi_version})
    end
  end

  describe '#create_vm' do
    let(:instance) { instance_double(Bosh::AwsCloud::Instance, id: 'fake-id') }
    let(:agent_id) {'agent_id'}
    let(:stemcell_id) {'stemcell_id'}
    let(:vm_type) { {} }

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

    before do
      allow_any_instance_of(Bosh::AwsCloud::Cloud).to receive(:create_vm).and_return(instance.id)
    end

    it 'should create an EC2 instance and return its id' do
      expect(cloud.create_vm(agent_id, stemcell_id, vm_type, networks_spec, disk_locality, environment)).to eq([instance.id, [], {}])
    end
  end

  describe '#attach_disk' do
    let(:instance_id){ 'i-test' }
    let(:volume_id) { 'v-foobar' }
    let(:device_name) { '/dev/sdf' }
    let(:instance) { instance_double(Aws::EC2::Instance, :id => instance_id ) }
    let(:volume) { instance_double(Aws::EC2::Volume, :id => volume_id) }
    let(:subnet) { instance_double(Aws::EC2::Subnet) }
    let(:fake_cloud_v1) {instance_double(Bosh::AwsCloud::Cloud, :attach_disk => {})}
    let(:endpoint) {'http://registry:3333'}
    # let(:registry) {instance_double(Bosh::Cpi::RegistryClient, :endpoint => endpoint, :read_setting => settings)}
    let(:settings) {
      {
        'foo' => 'bar',
        'disks' => {
          'persistent' => {
            'v-foobar' => '/dev/sdf'
          }
        }
      }
    }
    before do
      allow_any_instance_of(Bosh::AwsCloud::Cloud).to receive(:attach_disk).and_return({})
      allow_any_instance_of(Bosh::Cpi::RegistryClient).to receive(:read_settings).and_return(settings)
    end

    it 'should attach an EC2 volume to an instance' do
      expect(cloud.attach_disk(instance_id, volume_id, {})).to eq(device_name)
    end
  end
end
