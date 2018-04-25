require 'spec_helper'

describe Bosh::AwsCloud::CloudCore do
  subject(:cloud) { described_class.new(config, logger, volume_manager, az_selector) }

  let(:volume_manager) { instance_double(Bosh::AwsCloud::VolumeManager) }
  let(:az_selector) { instance_double(Bosh::AwsCloud::AvailabilityZoneSelector) }
  let(:api_version) { 2 }
  let(:logger) { Bosh::Clouds::Config.logger}
  let(:options) { mock_cloud_options['properties'] }
  let(:validate_registry) { true }
  let(:config) { Bosh::AwsCloud::Config.build(options, validate_registry) }
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

  describe '#info' do
    it 'returns correct info with default api_version' do
      expect(cloud.info).to eq({'stemcell_formats' => ['aws-raw', 'aws-light'], 'api_version' => api_version})
    end

    context 'when api_version is specified in config json' do
      let(:options) do
        mock_cloud_properties_merge(
          'api_version' => 42
        )
      end

      it 'returns correct api_version in info' do
        expect(cloud.info).to eq({'stemcell_formats' => ['aws-raw', 'aws-light'], 'api_version' => options['api_version']})
      end
    end
  end

  describe '#delete_vm' do
    let(:instance_manager) { instance_double(Bosh::AwsCloud::InstanceManager) }
    let(:instance_id) { 'fake-id' }
    let(:ec2) { instance_double(Aws::EC2::Resource) }
    let(:instance) { instance_double(Bosh::AwsCloud::Instance) }

    before do
      allow(Bosh::AwsCloud::InstanceManager).to receive(:new).and_return(instance_manager)
    end

    it 'deletes an EC2 instance' do
      allow(instance_manager).to receive(:find).with(instance_id).and_return(instance)
      expect(instance).to receive(:terminate).with(false)

      cloud.delete_vm(instance_id)
    end
  end
end
