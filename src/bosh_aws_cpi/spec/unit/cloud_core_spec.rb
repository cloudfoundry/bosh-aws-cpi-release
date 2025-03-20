require 'spec_helper'

describe Bosh::AwsCloud::CloudCore do
  subject(:cloud) {described_class.new(config, logger, volume_manager, az_selector, api_version)}

  let(:volume_manager) {instance_double(Bosh::AwsCloud::VolumeManager)}
  let(:az_selector) {instance_double(Bosh::AwsCloud::AvailabilityZoneSelector)}
  let(:api_version) {2}
  let(:logger) {Bosh::Clouds::Config.logger}
  let(:options) {mock_cloud_options['properties']}
  let(:config) {Bosh::AwsCloud::Config.build(options)}
  let(:az_selector) {instance_double(Bosh::AwsCloud::AvailabilityZoneSelector)}

  before do
    allow(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(az_selector)
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
          expect {cloud}.to raise_error(
                              ArgumentError,
                              'missing configuration parameters > aws:max_retries'
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
          expect {cloud}.to raise_error(
                              ArgumentError,
                              'missing configuration parameters > aws:region, or aws:ec2_endpoint and aws:elb_endpoint'
                            )
        end
      end

      context 'when all the required configurations are present' do
        it 'does not raise an error ' do
          expect {cloud}.to_not raise_error
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
        expect(cloud.info).to eq({'stemcell_formats' => ['aws-raw', 'aws-light'], 'api_version' => api_version})
      end
    end
  end

  describe '#delete_vm' do
    let(:instance_manager) {instance_double(Bosh::AwsCloud::InstanceManager)}
    let(:instance_id) {'fake-id'}
    let(:ec2) {instance_double(Aws::EC2::Resource)}
    let(:instance) {instance_double(Bosh::AwsCloud::Instance)}

    before do
      allow(Bosh::AwsCloud::InstanceManager).to receive(:new).and_return(instance_manager)
    end

    it 'deletes an EC2 instance' do
      allow(instance_manager).to receive(:find).with(instance_id).and_return(instance)
      expect(instance).to receive(:terminate).with(false)

      cloud.delete_vm(instance_id)
    end
  end

  describe '#create_vm' do
    let(:metadata_options) { {
      :http_tokens=> 'required',
      :http_put_response_hop_limit=> 1,
      :http_endpoint=> 'enabled'
    }}
    let(:instance_manager) {instance_double(Bosh::AwsCloud::InstanceManager)}
    let(:instance_id) {'fake-id'}
    let(:ec2) {instance_double(Aws::EC2::Resource)}
    let(:instance) {instance_double(Bosh::AwsCloud::Instance, {id: 'id'})}
    let(:settings) {instance_double(Bosh::AwsCloud::AgentSettings, {'agent_disk_info=': {}, 'agent_config=': {}, 'root_device_name=': '', encode: '{"json":"something"}'})}

    before do
      allow(Bosh::AwsCloud::BlockDeviceManager).to receive(:new).and_return(double(Bosh::AwsCloud::BlockDeviceManager, {mappings_and_info: ['block_device_mappings', 'agent_disk_info']}))
      allow(Bosh::AwsCloud::StemcellFinder).to receive(:find_by_id).and_return(double("stemcell", {root_device_name: "root_device_name", ami: 'ami', image_id: 'image_id'}))
      allow(Bosh::AwsCloud::NetworkConfigurator).to receive(:new).and_return(double("NetworkConfigurator", {configure: {}}))
      allow(Bosh::AwsCloud::InstanceManager).to receive(:new).and_return(instance_manager)
    end

    context 'when instance metadata is set in cpi config' do
      let(:options) {
        tmp = mock_cloud_options['properties']
        tmp['aws']['metadata_options']= metadata_options
        tmp
      }

      it 'passes instance metadata to AWS' do
        expect(instance_manager).to receive(:create).with(anything,anything,anything,anything,anything,anything,anything,anything,anything,metadata_options).and_return(instance)

        cloud.create_vm('foo', 'stemcell_id', 'vm_type', double('network_props', {filter: []}), settings)
      end
    end
    context 'when instance metadata is not set in cpi config' do

      it 'passes instance metadata to AWS' do
        expect(instance_manager).to receive(:create).with(anything,anything,anything,anything,anything,anything,anything,anything,anything,nil).and_return(instance)
        expect(options['aws']).to_not have_key('metadata_options')

        cloud.create_vm('foo', 'stemcell_id', 'vm_type', double('network_props', {filter: []}), settings)
      end
    end
  end
end
