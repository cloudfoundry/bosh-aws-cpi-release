require 'spec_helper'
require 'base64'

module Bosh::AwsCloud
  describe InstanceParamMapper do
    let(:logger) { Logger.new('/dev/null') }
    let(:instance_param_mapper) { InstanceParamMapper.new(logger) }
    let(:user_data) { {} }
    let(:mock_az_selector) { instance_double(Bosh::AwsCloud::AvailabilityZoneSelector) }
    let(:fake_nic_configuration) do
      [
        double('network_interface').tap do |nic|
          allow(nic).to receive(:nic_configuration) do |device_index = 0|
            {
              device_index: device_index,
              network_interface_id: 'eni-12345678',
            }
          end
          allow(nic).to receive(:availability_zone).and_return('region-1a')
        end
      ]
    end

    before do
      allow(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(mock_az_selector)
      allow(mock_az_selector).to receive(:common_availability_zone).and_return('region-1a')
    end

    let(:aws_config) do
      instance_double(Bosh::AwsCloud::AwsConfig)
    end
    let(:global_config) do
      instance_double(Bosh::AwsCloud::Config, aws: aws_config)
    end
    let(:vm_cloud_props) do
      Bosh::AwsCloud::VMCloudProps.new(vm_type, global_config)
    end
    let(:vm_type) { {} }

    before do
      allow(aws_config).to receive(:default_key_name)
      allow(aws_config).to receive(:default_iam_instance_profile)
      allow(aws_config).to receive(:encrypted)
      allow(aws_config).to receive(:kms_key_arn)
    end

    describe '#instance_params' do

      context 'when stemcell_id is provided' do
        let(:input) do
          {
            stemcell_id: 'fake-stemcell',
            vm_type: vm_cloud_props
          }
        end
        let(:output) do
           { image_id: 'fake-stemcell',
             placement: { availability_zone: 'region-1a' },
             network_interfaces:
              [
                device_index: 0,
                network_interface_id: "eni-12345678"
              ]
            }
        end

        it 'maps to image_id' do
          expect(mapping(input)).to eq(output)
        end
      end

      context 'when instance metadata is provided by the CPI config' do
        let(:input) do
          {
            vm_type: vm_cloud_props,
            metadata_options: {foo: 'bar'},
          }
        end

        let(:output) do
          {
            metadata_options: {foo: 'bar'},
            placement: { availability_zone: 'region-1a' },
            network_interfaces:
            [
              device_index: 0,
              network_interface_id: "eni-12345678"
            ]
          }
        end
        it 'passes metadata in output' do
          expect(mapping(input)).to eq(output)
        end
      end
      context 'when instance metadata is provided the CPI config AND cloud properties' do
        let(:vm_cloud_props) do
          Bosh::AwsCloud::VMCloudProps.new({ 'metadata_options' => { bar: 'baz' } }, global_config)
        end
        let(:input) do
          {
            vm_type: vm_cloud_props,
            metadata_options: {foo: 'bar', bar: 'quux'},
          }
        end

        let(:output) do
          {
            metadata_options: {foo: 'bar', bar: 'baz'},
            placement: { availability_zone: 'region-1a' },
            network_interfaces:
            [
              device_index: 0,
              network_interface_id: "eni-12345678"
            ]
          }
        end
        it 'passes merged metadata in output with the cloud properties taking precedence' do
          expect(mapping(input)).to eq(output)
        end
      end
      context 'when instance metadata is nil' do
        let(:input) do
          {
            vm_type: vm_cloud_props,
            metadata_options: nil
          }
        end
        it 'it omits metadata in output' do
          expect(mapping(input)).to_not have_key(:metadata_options)
        end
      end

      context 'when instance_type is provided by vm_type' do
        let(:vm_type) { { 'instance_type' => 'fake-instance' } }
        let(:input) do
          {
            vm_type: vm_cloud_props
          }
        end
        let(:output) do
          {
            instance_type: 'fake-instance',
            placement: { availability_zone: 'region-1a' },
            network_interfaces:
            [
              device_index: 0,
              network_interface_id: "eni-12345678"
            ]
          }

        end

        it 'maps to instance_type' do expect(mapping(input)).to eq(output) end
      end

      context 'when placement_group is provided by vm_type' do
        let(:vm_type) do
          { 'placement_group' => 'fake-group' }
        end
        let(:input) do
          {
            vm_type: vm_cloud_props
          }
        end
        let(:output) do
          {
            placement: { availability_zone: 'region-1a', group_name: 'fake-group' },
            network_interfaces:
            [
              device_index: 0,
              network_interface_id: "eni-12345678"
            ]
          }
        end

        it 'maps to placement.group_name' do expect(mapping(input)).to eq(output) end
      end

      describe 'Tenancy options' do
        context 'when tenancy is provided by vm_type, as "dedicated"' do
          let(:vm_type) { { 'tenancy' => 'dedicated' } }
          let(:input) do
            {
              vm_type: vm_cloud_props
            }
          end
          let(:output) do
            {
              placement: { availability_zone: 'region-1a', tenancy: 'dedicated' },
              network_interfaces:
              [
                device_index: 0,
                network_interface_id: "eni-12345678"
              ]
            }
          end

          it 'maps to placement.tenancy' do expect(mapping(input)).to eq(output) end
        end

        context 'when tenancy is provided by vm_type, as other than "dedicated"' do
          let(:vm_type) { { 'tenancy' => 'ignored' } }
          let(:input) do
            { vm_type: vm_cloud_props
            }
          end
          let(:output) do
            {
              placement: { availability_zone: 'region-1a' },
              network_interfaces:
              [
                device_index: 0,
                network_interface_id: "eni-12345678"
              ]
            }
        end

          it 'is ignored' do expect(mapping(input)).to eq(output) end
        end
      end

      describe 'Key Name options' do
        context 'when key_name is provided by defaults (only)' do
          let(:input) do
            {
              vm_type: vm_cloud_props
            }
          end
          let(:output) do
            {
              key_name: 'default-fake-key-name',
              placement: { availability_zone: 'region-1a' },
              network_interfaces:
              [
                device_index: 0,
                network_interface_id: "eni-12345678"
              ]
            }
          end

          before do
            expect(aws_config).to receive(:default_key_name).and_return('default-fake-key-name')
          end

          it 'maps key_name from defaults' do expect(mapping(input)).to eq(output) end
        end

        context 'when key_name is provided by defaults and vm_type' do
          let(:vm_type) { { 'key_name' => 'fake-key-name' } }
          let(:input) do
            {
              vm_type: vm_cloud_props
            }
          end
          let(:output) do
             { 
              key_name: 'fake-key-name',
              placement: { availability_zone: 'region-1a' },
              network_interfaces:
              [
                device_index: 0,
                network_interface_id: "eni-12345678"
              ]
             }
          end

          it 'maps key_name from vm_type' do
            expect(mapping(input)).to eq(output)
          end
        end
      end

      describe 'IAM instance profile options' do
        context 'when iam_instance_profile is provided by defaults (only)' do
          let(:input) do
            {
              vm_type: vm_cloud_props
            }
          end
          let(:output) do
             { 
              iam_instance_profile: { name: 'default-fake-iam-profile' },
              placement: { availability_zone: 'region-1a' },
              network_interfaces:
              [
                device_index: 0,
                network_interface_id: "eni-12345678"
              ]
             }
          end

          before do
            expect(aws_config).to receive(:default_iam_instance_profile).and_return('default-fake-iam-profile')
          end

          it 'maps iam_instance_profile from defaults' do
            expect(mapping(input)).to eq(output)
          end
        end

        context 'when iam_instance_profile is provided by defaults and vm_type' do
          let(:vm_type) { { 'iam_instance_profile' => 'fake-iam-profile' } }
          let(:input) do
            {
              vm_type: vm_cloud_props
            }
          end
          let(:output) do
             { 
              iam_instance_profile: { name: 'fake-iam-profile' },
              placement: { availability_zone: 'region-1a' },
              network_interfaces:
              [
                device_index: 0,
                network_interface_id: "eni-12345678"
              ]
             }
          end

          it 'maps iam_instance_profile from vm_type' do expect(mapping(input)).to eq(output) end
        end
      end

      context 'user_data should be present in instance_params' do
        let(:user_data) { Base64.encode64('{"registry":{"endpoint":"example.com"}}').strip }
        let(:input) do
          {
            vm_type: vm_cloud_props,
            user_data: user_data
          }
        end
        let(:output) do
          {
            user_data: user_data,
            placement: { availability_zone: 'region-1a' },
            network_interfaces:
            [
              device_index: 0,
              network_interface_id: "eni-12345678"
            ]
          }
        end

        it 'maps to Base64 encoded user_data.registry.endpoint' do
          expect(mapping(input)).to eq(output)
        end
      end

      describe 'Availability Zone options' do
        context 'when availability zone is determined by AvailabilityZoneSelector' do
          let(:vm_type) { { 'availability_zone' => 'region-1b' } }
          let(:input) do
            {
              vm_type: vm_cloud_props,
              volume_zones: ['region-1c']
            }
          end
          let(:output) do
             {
              placement: { availability_zone: 'region-1a' },
              network_interfaces:
              [
                device_index: 0,
                network_interface_id: "eni-12345678"
              ]
              }
            end
          
          before do
            expect(mock_az_selector).to receive(:common_availability_zone)
              .with(['region-1c'], 'region-1b', 'region-1a')
              .and_return('region-1a')
          end

          it 'maps placement.availability_zone using AvailabilityZoneSelector logic' do
            expect(mapping(input)).to eq(output)
          end
        end
        
        context 'when AvailabilityZoneSelector returns nil' do
          let(:input) do
            {
              vm_type: vm_cloud_props
            }
          end
          let(:output) do
             {
              network_interfaces:
              [
                device_index: 0,
                network_interface_id: "eni-12345678"
              ]
              }
            end
          
          before do
            allow(mock_az_selector).to receive(:common_availability_zone).and_return(nil)
          end

          it 'omits placement when availability zone is nil' do
            expect(mapping(input)).to eq(output)
          end
        end
        
        context 'when volume_zones are provided' do
          let(:input) do
            {
              vm_type: vm_cloud_props,
              volume_zones: ['region-1c', 'region-1d']
            }
          end
          let(:output) do
             {
              placement: { availability_zone: 'region-1a' },
              network_interfaces:
              [
                device_index: 0,
                network_interface_id: "eni-12345678"
              ]
              }
            end
          
          before do
            expect(mock_az_selector).to receive(:common_availability_zone)
              .with(['region-1c', 'region-1d'], nil, 'region-1a')
              .and_return('region-1a')
          end

          it 'passes volume_zones to AvailabilityZoneSelector' do
            expect(mapping(input)).to eq(output)
          end
        end
      end

      context 'when block_device_mappings are provided' do
        let(:input) do
          {
            vm_type: vm_cloud_props,
            block_device_mappings: ['fake-device']
          }
        end
        let(:output) do
          {
            block_device_mappings: ['fake-device'],
            placement: { availability_zone: 'region-1a' },
            network_interfaces:
            [
              device_index: 0,
              network_interface_id: "eni-12345678"
            ]
          }
          end

        it 'passes the mapping through to the output' do
          expect(mapping(input)).to eq(output)
        end
      end

      context 'when a full spec is provided' do
        context 'with security group IDs' do
          let(:user_data) { Base64.encode64('{"registry":{"endpoint":"example.com"}}').strip }
          let(:vm_type) do
            {
              'instance_type' => 'fake-instance-type',
              'availability_zone' => 'region-1a',
              'key_name' => 'fake-key-name',
              'iam_instance_profile' => 'fake-iam-profile',
              'security_groups' => ['sg-12345678', 'sg-23456789'],
              'tenancy' => 'dedicated',

            }
          end
          let(:input) do
            {
              stemcell_id: 'ami-something',
              vm_type: vm_cloud_props,
              block_device_mappings: ['fake-device'],
              user_data: user_data
            }
          end
          let(:output) do
            {
              image_id: 'ami-something',
              instance_type: 'fake-instance-type',
              placement: {
                availability_zone: 'region-1a',
                tenancy: 'dedicated'
              },
              key_name: 'fake-key-name',
              iam_instance_profile: { name: 'fake-iam-profile' },
              network_interfaces:
              [
                device_index: 0,
                network_interface_id: "eni-12345678"
              ],
              user_data: user_data,
              block_device_mappings: ['fake-device']
            }
          end

          it 'correctly renders the instance params' do
            expect(mock_az_selector).to receive(:common_availability_zone)
              .with([], 'region-1a', 'region-1a')
              .and_return('region-1a')
            expect(mapping(input)).to eq(output)
          end
        end
      end

      describe 'tags' do
        context 'when tags are supplied' do
          it 'constructs tag specification' do
            instance_param_mapper.manifest_params = {
              vm_type: vm_cloud_props,
              tags: { 'tag' => 'tag_value' }
            }
            expect(instance_param_mapper.instance_params(fake_nic_configuration)[:tag_specifications]).to_not be_nil
            expect(instance_param_mapper.instance_params(fake_nic_configuration)[:tag_specifications][0][:tags]).to eq([{key: 'tag', value: 'tag_value'}])
            expect(instance_param_mapper.instance_params(fake_nic_configuration)[:tag_specifications][0][:resource_type]).to eq('instance')
          end
        end
      end
    end

    describe '#validate' do
      before do
        instance_param_mapper.manifest_params = {
          vm_type: vm_cloud_props
        }
      end

      it 'calls both validate_required_inputs and validate_availability_zone' do
        expect(instance_param_mapper).to receive(:validate_required_inputs)
        expect(instance_param_mapper).to receive(:validate_availability_zone).with('us-east-1a')
        instance_param_mapper.validate('us-east-1a')
      end

      context 'with valid input' do
        let(:user_data) { Base64.encode64('{"registry":{"endpoint":"example.com"}}').strip }
        let(:vm_type) do
          {
            'instance_type' => 'fake-instance-type',
            'availability_zone' => 'region-1a',
            'key_name' => 'fake-key-name'
          }
        end

        it 'does not raise an exception on valid input' do
          instance_param_mapper.manifest_params = {
            stemcell_id: 'ami-something',
            vm_type: vm_cloud_props,
            user_data: user_data
          }
          expect {
            instance_param_mapper.validate('us-east-1a')
          }.to_not raise_error
        end
      end

      context 'with invalid input' do
        it 'raises an exception when user_data is missing' do
          instance_param_mapper.manifest_params = {
            stemcell_id: 'ami-something',
            vm_type: vm_cloud_props,
          }
          expect {
            instance_param_mapper.validate('us-east-1a')
          }.to raise_error Bosh::Clouds::CloudError, /Missing properties: user_data/
        end
      end
    end

    describe '#validate_required_inputs' do
      before do
        instance_param_mapper.manifest_params = {
          vm_type: vm_cloud_props
        }
      end

      it 'raises an exception if any required properties are not provided' do
        required_inputs = [
          'stemcell_id',
          'user_data',
          'cloud_properties.instance_type',
          'cloud_properties.availability_zone'
        ]

        required_inputs.each do |input_name|
          expect {
            instance_param_mapper.validate_required_inputs
          }.to raise_error(Regexp.new(input_name))
        end
      end
    end

    describe '#validate_availability_zone' do
      before do
        instance_param_mapper.manifest_params = {
          vm_type: vm_cloud_props
        }
      end

      it 'validates availability zone configuration' do
        expect(instance_param_mapper.validate_availability_zone('us-east-1a')).to be_truthy
      end
    end

    private

    def mapping(input)
      instance_param_mapper.manifest_params = input
      instance_param_mapper.instance_params(fake_nic_configuration)
    end
  end
end
