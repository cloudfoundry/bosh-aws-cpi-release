require 'spec_helper'
require 'base64'

module Bosh::AwsCloud
  describe InstanceParamMapper do
    let(:logger) { Logger.new('/dev/null') }
    let(:instance_param_mapper) { InstanceParamMapper.new(security_group_mapper, logger) }
    let(:user_data) { {} }
    let(:security_group_mapper) { SecurityGroupMapper.new(ec2_resource) }
    let(:ec2_resource) { instance_double(Aws::EC2::Resource) }
    let(:security_groups) do
      [
        instance_double(Aws::EC2::SecurityGroup, group_name: 'sg-1-name', id: 'sg-11111111'),
        instance_double(Aws::EC2::SecurityGroup, group_name: 'sg-2-name', id: 'sg-22222222'),
        instance_double(Aws::EC2::SecurityGroup, group_name: 'sg-3-name', id: 'sg-33333333'),
        instance_double(Aws::EC2::SecurityGroup, group_name: 'sg-4-name', id: 'sg-44444444'),
        instance_double(Aws::EC2::SecurityGroup, group_name: 'sg-5-name', id: 'sg-55555555'),
        instance_double(Aws::EC2::SecurityGroup, group_name: 'sg-6-name', id: 'sg-66666666'),
        instance_double(Aws::EC2::SecurityGroup, group_name: 'sg-7-name', id: 'sg-77777777')
      ]
    end
    let(:dynamic_subnet_id) { 'dynamic-subnet' }
    let(:manual_subnet_id) { 'manual-subnet' }
    let(:shared_subnet) do
      instance_double(Aws::EC2::Subnet,
        vpc: instance_double(Aws::EC2::Vpc, security_groups: security_groups))
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
    let(:networks_spec) { {} }
    let(:network_cloud_props) do
      Bosh::AwsCloud::NetworkCloudProps.new(networks_spec, global_config)
    end

    before do
      allow(aws_config).to receive(:default_key_name)
      allow(aws_config).to receive(:default_iam_instance_profile)
      allow(aws_config).to receive(:encrypted)
      allow(aws_config).to receive(:kms_key_arn)

      allow(ec2_resource).to receive(:subnet).with(dynamic_subnet_id).and_return(shared_subnet)
    end

    describe '#instance_params' do

      context 'when stemcell_id is provided' do
        let(:input) do
          {
            stemcell_id: 'fake-stemcell',
            vm_type: vm_cloud_props,
            networks_spec: network_cloud_props
          }
        end
        let(:output) { { image_id: 'fake-stemcell' } }

        it 'maps to image_id' do
          expect(mapping(input)).to eq(output)
        end
      end

      context 'when instance metadata is provided by the CPI config' do
        let(:input) do
          {
            vm_type: vm_cloud_props,
            networks_spec: network_cloud_props,
            metadata_options: {foo: 'bar'},
          }
        end
        it 'passes metadata in output' do
          expect(mapping(input)).to eq({ metadata_options: {foo: 'bar'} })
        end
      end
      context 'when instance metadata is provided the CPI config AND cloud properties' do
        let(:vm_cloud_props) do
          Bosh::AwsCloud::VMCloudProps.new({ 'metadata_options' => { bar: 'baz' } }, global_config)
        end
        let(:input) do
          {
            vm_type: vm_cloud_props,
            networks_spec: network_cloud_props,
            metadata_options: {foo: 'bar', bar: 'quux'},
          }
        end
        it 'passes merged metadata in output with the cloud properties taking precedence' do
          expect(mapping(input)).to eq({ metadata_options: {foo: 'bar', bar: 'baz'} })
        end
      end
      context 'when instance metadata is nil' do
        let(:input) do
          {
            vm_type: vm_cloud_props,
            networks_spec: network_cloud_props,
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
            vm_type: vm_cloud_props,
            networks_spec: network_cloud_props
          }
        end
        let(:output) { { instance_type: 'fake-instance' } }

        it 'maps to instance_type' do expect(mapping(input)).to eq(output) end
      end

      context 'when placement_group is provided by vm_type' do
        let(:vm_type) do
          { 'placement_group' => 'fake-group' }
        end
        let(:input) do
          {
            vm_type: vm_cloud_props,
            networks_spec: network_cloud_props
          }
        end
        let(:output) { { placement: { group_name: 'fake-group' } } }

        it 'maps to placement.group_name' do expect(mapping(input)).to eq(output) end
      end

      describe 'Tenancy options' do
        context 'when tenancy is provided by vm_type, as "dedicated"' do
          let(:vm_type) { { 'tenancy' => 'dedicated' } }
          let(:input) do
            {
              vm_type: vm_cloud_props,
              networks_spec: network_cloud_props
            }
          end
          let(:output) { { placement: { tenancy: 'dedicated' } } }

          it 'maps to placement.tenancy' do expect(mapping(input)).to eq(output) end
        end

        context 'when tenancy is provided by vm_type, as other than "dedicated"' do
          let(:vm_type) { { 'tenancy' => 'ignored' } }
          let(:input) do
            { vm_type: vm_cloud_props,
              networks_spec: network_cloud_props
            }
          end
          let(:output) { {} }

          it 'is ignored' do expect(mapping(input)).to eq(output) end
        end
      end

      describe 'Key Name options' do
        context 'when key_name is provided by defaults (only)' do
          let(:input) do
            {
              vm_type: vm_cloud_props,
              networks_spec: network_cloud_props
            }
          end
          let(:output) { { key_name: 'default-fake-key-name' } }

          before do
            expect(aws_config).to receive(:default_key_name).and_return('default-fake-key-name')
          end

          it 'maps key_name from defaults' do expect(mapping(input)).to eq(output) end
        end

        context 'when key_name is provided by defaults and vm_type' do
          let(:vm_type) { { 'key_name' => 'fake-key-name' } }
          let(:input) do
            {
              vm_type: vm_cloud_props,
              networks_spec: network_cloud_props
            }
          end
          let(:output) { { key_name: 'fake-key-name' } }

          it 'maps key_name from vm_type' do
            expect(mapping(input)).to eq(output)
          end
        end
      end

      describe 'IAM instance profile options' do
        context 'when iam_instance_profile is provided by defaults (only)' do
          let(:input) do
            {
              vm_type: vm_cloud_props,
              networks_spec: network_cloud_props
            }
          end
          let(:output) { { iam_instance_profile: { name: 'default-fake-iam-profile' } } }

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
              vm_type: vm_cloud_props,
              networks_spec: network_cloud_props
            }
          end
          let(:output) { { iam_instance_profile: { name: 'fake-iam-profile' } } }

          it 'maps iam_instance_profile from vm_type' do expect(mapping(input)).to eq(output) end
        end
      end

      describe 'Security Group options' do
        context 'when security_groups is provided by defaults (only)' do
          let(:networks_spec) do
            {
              'net1' => {
                'cloud_properties' => {
                  'subnet' => dynamic_subnet_id
                }
              }
            }
          end
          let(:input) do
            {
              vm_type: vm_cloud_props,
              networks_spec: network_cloud_props,
              default_security_groups: %w(sg-11111111 sg-2-name)
            }
          end
          let(:output) do
            {
              network_interfaces: [{
                device_index: 0,
                subnet_id: dynamic_subnet_id,
                groups: ['sg-11111111', 'sg-22222222']
              }]
            }
          end

          it 'maps network_interfaces.first[:groups] from defaults' do
            expect(mapping(input)).to eq(output)
          end
        end

        context 'when security_groups is provided by defaults and networks_spec' do
          let(:networks_spec) do
            {
              'net1' => {
                'cloud_properties' => {
                  'security_groups' => ['sg-11111111', 'sg-2-name'],
                  'subnet' => dynamic_subnet_id
                },
                'type' => 'dynamic'
              },
              'net2' => {
                'cloud_properties' => {
                  'security_groups' => 'sg-33333333',
                  'subnet' => dynamic_subnet_id
                },
                'type' => 'dynamic'
              }
            }
          end
          let(:input) do
            {
              vm_type: vm_cloud_props,
              networks_spec: network_cloud_props,
              default_security_groups: %w(sg-44444444 sg-5-name)
            }
          end
          let(:output) do
            {
              network_interfaces: [{
                device_index: 0,
                subnet_id: dynamic_subnet_id,
                groups: ['sg-11111111', 'sg-22222222', 'sg-33333333']
              }]
            }
          end

          it 'maps network_interfaces.first[:groups] from networks_spec' do
            expect(mapping(input)).to eq(output)
          end
        end

        context 'when security_groups is provided by defaults, networks_spec, and vm_type' do
          let(:vm_type) { { 'security_groups' => ['sg-11111111', 'sg-2-name'] } }
          let(:networks_spec) do
            {
              'net1' => {
                'cloud_properties' => {
                  'security_groups' => ['sg-33333333', 'sg-4-name'],
                  'subnet' => dynamic_subnet_id
                },
                'type' => 'dynamic'
              },
              'net2' => {
                'cloud_properties' => {
                  'security_groups' => 'sg-55555555',
                  'subnet' => dynamic_subnet_id
                },
                'type' => 'dynamic'
              }
            }
          end
          let(:input) do
            {
              vm_type: vm_cloud_props,
              networks_spec: network_cloud_props,
              default_security_groups: %w(sg-6-name sg-77777777)
            }
          end
          let(:output) do
            {
              network_interfaces: [{
                device_index: 0,
                subnet_id: dynamic_subnet_id,
                groups: ['sg-11111111', 'sg-22222222']
              }]
            }
          end

          it 'maps network_interfaces.first[:groups] from vm_type' do
            expect(mapping(input)).to eq(output)
          end
        end
      end

      context 'user_data should be present in instance_params' do
        let(:user_data) { Base64.encode64('{"registry":{"endpoint":"example.com"}}').strip }
        let(:input) do
          {
            vm_type: vm_cloud_props,
            networks_spec: network_cloud_props,
            user_data: user_data
          }
        end
        let(:output) { { user_data: user_data } }

        it 'maps to Base64 encoded user_data.registry.endpoint' do
          expect(mapping(input)).to eq(output)
        end
      end

      context 'when dns is provided by networks in networks_spec' do
        let(:user_data) { Base64.encode64("{'networks' => #{agent_network_spec(network_cloud_props)}}".to_json).strip }
        let(:networks_spec) do
          {
            'net1' => {},
            'net2' => { 'dns' => '1.1.1.1' },
            'net3' => { 'dns' => '2.2.2.2' }
          }
        end
        let(:input) do
          {
            vm_type: vm_cloud_props,
            networks_spec: network_cloud_props,
            user_data: user_data
          }
        end
        let(:output) { { user_data: user_data } }

        it 'maps to Base64 encoded user_data.dns, from the first matching network' do
          expect(mapping(input)).to eq(output)
        end
      end

      context 'when no meaningful network is given' do
        let(:user_data) { Base64.encode64("{'networks' => #{agent_network_spec(network_cloud_props)}}".to_json).strip }
        let(:networks_spec) do
          {
            'net1' => {},
            'net2' => { 'ip' => '1.1.1.1' },
            'net3' => { 'ip' => '2006::1' }
          }
        end
        let(:input) do
          {
            vm_type: vm_cloud_props,
            networks_spec: network_cloud_props,
            user_data: user_data
          }
        end
        let(:output) do
          {
            user_data: user_data
          }
        end

        it 'does not attach a network interface' do
          expect(mapping(input)).to eq(output)
        end
      end

      describe 'IP address options' do
        context 'when associate_public_ip_address is true' do
          let(:vm_type) { { 'auto_assign_public_ip' => true } }
          let(:input) do
            {
              vm_type: vm_cloud_props,
              networks_spec: network_cloud_props,
            }
          end
          let(:output) do
            {
              network_interfaces: [
                {
                  associate_public_ip_address: true,
                  device_index: 0
                }
              ]
            }
          end

          it 'adds the option to the output' do
            expect(mapping(input)).to eq(output)
          end
        end

        context 'when associate_public_ip_address is false' do
          let(:vm_type) { { 'auto_assign_public_ip' => false } }
          let(:input) do
            {
                vm_type: vm_cloud_props,
                networks_spec: network_cloud_props,
            }
          end
          let(:output) do
            {
                network_interfaces: [
                    {
                        associate_public_ip_address: false,
                        device_index: 0
                    }
                ]
            }
          end

          it 'adds the option to the output' do
            expect(mapping(input)).to eq(output)
          end
        end
      end

      describe 'Subnet options' do
        context 'when subnet is provided by manual (explicit or implicit)' do
          let(:networks_spec) do
            {
              'net1' => {
                'type' => 'vip',
                'cloud_properties' => { 'subnet' => 'vip-subnet' }
              },
              'net2' => {
                'cloud_properties' => { 'subnet' => manual_subnet_id }
              }
            }
          end
          let(:input) do
            {
              vm_type: vm_cloud_props,
              networks_spec: network_cloud_props,
              subnet_az_mapping: {
                manual_subnet_id => 'region-1b'
              }
            }
          end
          let(:output) do
            {
              network_interfaces: [
                {
                  subnet_id: manual_subnet_id,
                  device_index: 0
                }
              ],
              placement: { availability_zone: 'region-1b' }
            }
          end

          it 'maps subnet from the first matching network to subnet_id' do
            expect(mapping(input)).to eq(output)
          end
        end

        context 'when subnet is provided by manual (explicit or implicit) or dynamic networks in networks_spec' do
          let(:networks_spec) do
            {
              'net1' => {
                'type' => 'dynamic',
                'cloud_properties' => { 'subnet' => dynamic_subnet_id }
              },
              'net2' => {
                'type' => 'manual',
                'cloud_properties' => { 'subnet' => manual_subnet_id }
              }
            }
          end
          let(:input) do
            {
              vm_type: vm_cloud_props,
              networks_spec: network_cloud_props,
              subnet_az_mapping: {
                dynamic_subnet_id => 'region-1a',
                manual_subnet_id => 'region-1b'
              }
            }
          end
          let(:output) do
            {
              placement: {
                availability_zone: 'region-1a'
              },
              network_interfaces: [
                {
                  subnet_id: dynamic_subnet_id,
                  device_index: 0
                }
              ]
            }
          end

          it 'maps subnet from the first matching network to subnet_id' do
            expect(mapping(input)).to eq(output)
          end
        end

        context 'when two manual subnets with the same subnet_id are provided' do
          let(:networks_spec) do
            {
              'net1' => {
                'type' => 'manual',
                'cloud_properties' => { 'subnet' => manual_subnet_id },
                'ip' => '1.1.1.1'
              },
              'net2' => {
                'type' => 'manual',
                'cloud_properties' => { 'subnet' => manual_subnet_id },
                'ip' => '2600::1'
              }
            }
          end
          let(:input) do
            {
              vm_type: vm_cloud_props,
              networks_spec: network_cloud_props,
            }
          end
          let(:output) do
            {
              network_interfaces: [
                {
                  subnet_id: manual_subnet_id,
                  ipv_6_addresses: [{
                    ipv_6_address: '2600::1',
                  },
                ],
                  private_ip_address: '1.1.1.1',
                  device_index: 0
                }
              ]
            }
          end

          it 'attaches an ipv4 and an ipv6 to the nic' do
            allow(logger).to receive(:info)

            expect(mapping(input)).to eq(output)

            expect(logger).to have_received(:info).with("Running in dual stack mode")          end
        end


        context 'when two manual subnets with different subnet_ids are provided' do
          let(:networks_spec) do
            {
              'net1' => {
                'type' => 'manual',
                'cloud_properties' => { 'subnet' => manual_subnet_id },
                'ip' => '1.1.1.1'
              },
              'net2' => {
                'type' => 'manual',
                'cloud_properties' => { 'subnet' => 'different-subnet' },
                'ip' => '2600::1'
              }
            }
          end
          let(:input) do
            {
              vm_type: vm_cloud_props,
              networks_spec: network_cloud_props,
            }
          end
          let(:output) do
            {
              network_interfaces: [
                {
                  subnet_id: manual_subnet_id,
                  private_ip_address: '1.1.1.1',
                  device_index: 0
                }
              ]
            }
          end

          it 'attaches an ipv4 and an ipv6 to the nic' do
            expect(mapping(input)).to eq(output)
          end
        end

        context 'when two manual subnets with different subnet_ids are provided' do
          let(:networks_spec) do
            {
              'net1' => {
                'type' => 'manual',
                'cloud_properties' => { 'subnet' => manual_subnet_id },
                'ip' => '1.1.1.1'
              },
              'net2' => {
                'type' => 'manual',
                'cloud_properties' => { 'subnet' => manual_subnet_id },
                'ip' => '2.2.2.2'
              }
            }
          end
          let(:input) do
            {
              vm_type: vm_cloud_props,
              networks_spec: network_cloud_props,
            }
          end

          it 'raises an error message if no ipv6 address is provided' do
            expect{ mapping(input)}.to raise_error Bosh::Clouds::CloudError, /Dual Stack Mode: No ipv6 address assigned/
          end
        end


        context 'when two manual subnets with different subnet_ids are provided' do
          let(:networks_spec) do
            {
              'net1' => {
                'type' => 'manual',
                'cloud_properties' => { 'subnet' => manual_subnet_id },
                'ip' => '2600::1'
              },
              'net2' => {
                'type' => 'manual',
                'cloud_properties' => { 'subnet' => manual_subnet_id },
                'ip' => '2600::2'
              }
            }
          end
          let(:input) do
            {
              vm_type: vm_cloud_props,
              networks_spec: network_cloud_props,
            }
          end

          it 'raises an error message if no ipv6 address is applied' do
            expect{ mapping(input)}.to raise_error Bosh::Clouds::CloudError, /Dual Stack Mode: No ipv4 address assigned/
          end
        end
      end

      describe 'Availability Zone options' do
        let(:vm_type) do
          {
            'availability_zone' => 'region-1a'
          }
        end
        context 'when (only) resource pool AZ is provided' do
          let(:input) do
            {
              vm_type: vm_cloud_props,
              networks_spec: network_cloud_props
            }
          end
          let(:output) { { placement: { availability_zone: 'region-1a' } } }
          it 'maps placement.availability_zone from vm_type' do
            expect(mapping(input)).to eq(output)
          end
        end

        context 'when resource pool AZ, and networks AZs are provided' do
          let(:networks_spec) do
            {
              'net1' => {
                'type' => 'dynamic',
                'cloud_properties' => { 'subnet' => dynamic_subnet_id }
              }
            }
          end
          let(:input) do
            {
              vm_type: vm_cloud_props,
              networks_spec: network_cloud_props,
              subnet_az_mapping: {
                dynamic_subnet_id => 'region-1a'
              }
            }
          end
          let(:output) do
            {
              placement: {
                availability_zone: 'region-1a'
              },
              network_interfaces: [
                {
                  subnet_id: dynamic_subnet_id,
                  device_index: 0
                }
              ]
            }
          end

          it 'maps placement.availability_zone from the common availability zone' do
            expect(mapping(input)).to eq(output)
          end
        end

        context 'when volume AZs, resource pool AZ, and networks AZs are provided' do
          let(:networks_spec) do
            {
              'net1' => {
                'type' => 'dynamic',
                'cloud_properties' => { 'subnet' => dynamic_subnet_id }
              }
            }
          end
          let(:input) do
            {
              volume_zones: ['region-1a', 'region-1a'],
              vm_type: vm_cloud_props,
              networks_spec: network_cloud_props,
              subnet_az_mapping: {
                dynamic_subnet_id => 'region-1a'
              }
            }
          end
          let(:output) do
            {
              placement: {
                availability_zone: 'region-1a'
              },
              network_interfaces: [
                {
                  subnet_id: dynamic_subnet_id,
                  device_index: 0
                }
              ]
            }
          end

          it 'maps placement.availability_zone from the common availability zone' do
            expect(mapping(input)).to eq(output)
          end
        end
      end

      context 'when block_device_mappings are provided' do
        let(:input) do
          {
            vm_type: vm_cloud_props,
            networks_spec: network_cloud_props,
            block_device_mappings: ['fake-device']
          }
        end
        let(:output) { { block_device_mappings: ['fake-device'] } }

        it 'passes the mapping through to the output' do
          expect(mapping(input)).to eq(output)
        end
      end

      context 'when a full spec is provided' do
        context 'with security group IDs' do
          let(:user_data) { Base64.encode64("{'networks' => #{agent_network_spec(network_cloud_props)}}".to_json).strip }
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
          let(:networks_spec) do
            {
              'net1' => {
                'type' => 'manual',
                'ip' => '1.1.1.1',
                'dns' => '8.8.8.8',
                'cloud_properties' => { 'subnet' => manual_subnet_id }
              }
            }
          end
          let(:input) do
            {
              stemcell_id: 'ami-something',
              vm_type: vm_cloud_props,
              networks_spec: network_cloud_props,
              subnet_az_mapping: {
                dynamic_subnet_id => 'region-1a'
              },
              volume_zones: ['region-1a', 'region-1a'],
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
              network_interfaces: [
                {
                  subnet_id: manual_subnet_id,
                  private_ip_address: '1.1.1.1',
                  device_index: 0,
                  groups: ['sg-12345678', 'sg-23456789'],
                }
              ],
              user_data: user_data,
              block_device_mappings: ['fake-device']
            }
          end

          it 'correctly renders the instance params' do
            expect(mapping(input)).to eq(output)
          end
        end
      end

      describe 'tags' do
        context 'when tags are supplied' do
          it 'constructs tag specification' do
            instance_param_mapper.manifest_params = {
              vm_type: vm_cloud_props,
              networks_spec: network_cloud_props,
              tags: { 'tag' => 'tag_value' }
            }
            expect(instance_param_mapper.instance_params[:tag_specifications]).to_not be_nil
            expect(instance_param_mapper.instance_params[:tag_specifications][0][:tags]).to eq([{key: 'tag', value: 'tag_value'}])
            expect(instance_param_mapper.instance_params[:tag_specifications][0][:resource_type]).to eq('instance')
          end
        end
      end
    end

    describe '#validate_required_inputs' do
      before do
        instance_param_mapper.manifest_params = {
          vm_type: vm_cloud_props,
          networks_spec: network_cloud_props
        }
      end

      it 'raises an exception if any required properties are not provided' do
        required_inputs = [
          'stemcell_id',
          'user_data',
          'cloud_properties.instance_type',
          'cloud_properties.availability_zone',
          '\(cloud_properties.security_groups or global default_security_groups\)',
          'cloud_properties.subnet_id'
        ]

        required_inputs.each do |input_name|
          expect {
            instance_param_mapper.validate_required_inputs
          }.to raise_error(Regexp.new(input_name))
        end
      end
    end

    describe '#validate_availability_zone' do
      let(:vm_type) { { 'availability_zone' => 'region-1a' } }
      let(:networks_spec) do
        {
          'net1' => {
            'type' => 'dynamic',
            'cloud_properties' => { 'subnet' => dynamic_subnet_id }
          }
        }
      end
      it 'raises an error when provided AZs do not match' do
        instance_param_mapper.manifest_params = {
          volume_zones: ['region-1a', 'region-1a'],
          vm_type: vm_cloud_props,
          networks_spec: network_cloud_props,
          subnet_az_mapping: {
            dynamic_subnet_id => 'region-1b'
          }
        }
        expect {
          instance_param_mapper.validate_availability_zone
        }.to raise_error Bosh::Clouds::CloudError, /can't use multiple availability zones/
      end
    end

    describe '#validate' do
      let(:user_data) { Base64.encode64('{"registry":{"endpoint":"example.com"}}').strip }
      let(:vm_type) do
        {
          'instance_type' => 'fake-instance-type',
          'availability_zone' => 'region-1a',
          'key_name' => 'fake-key-name',
          'security_groups' => ['sg-12345678']
        }
      end
      let(:networks_spec) do
        {
          'net1' => {
            'type' => 'dynamic',
            'cloud_properties' => { 'subnet' => dynamic_subnet_id }
          }
        }
      end

      it 'does not raise an exception on valid input' do
        instance_param_mapper.manifest_params = {
          stemcell_id: 'ami-something',
          vm_type: vm_cloud_props,
          networks_spec: network_cloud_props,
          user_data: user_data
        }
        expect {
          instance_param_mapper.validate
        }.to_not raise_error
      end

      context 'invalid input' do
        it 'raises an exception' do
          instance_param_mapper.manifest_params = {
            stemcell_id: 'ami-something',
            vm_type: vm_cloud_props,
            networks_spec: network_cloud_props,
          }
          expect {
            instance_param_mapper.validate
          }.to raise_error Bosh::Clouds::CloudError, /Missing properties: user_data/
        end
      end
    end

    private

    def mapping(input)
      instance_param_mapper.manifest_params = input
      instance_param_mapper.instance_params
    end

    def agent_network_spec(networks_cloud_props)
      spec = networks_cloud_props.networks.map do |net|
        settings = net.to_h
        settings['use_dhcp'] = true

        [net.name, settings]
      end
      Hash[spec]
    end
  end
end
