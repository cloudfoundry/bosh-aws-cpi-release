require "spec_helper"

module Bosh::AwsCloud
  describe InstanceParamMapper do
    let(:instance_param_mapper) { InstanceParamMapper.new(security_group_mapper) }
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

    before do
      allow(ec2_resource).to receive(:subnet).with(dynamic_subnet_id).and_return(shared_subnet)
    end

    describe '#instance_params' do

      context 'when stemcell_id is provided' do
        let(:input) { { stemcell_id: 'fake-stemcell' } }
        let(:output) { { image_id: 'fake-stemcell' } }

        it 'maps to image_id' do expect(mapping(input)).to eq(output) end
      end

      context 'when instance_type is provided by vm_type' do
        let(:input) { { vm_type: { 'instance_type' => 'fake-instance' } } }
        let(:output) { { instance_type: 'fake-instance' } }

        it 'maps to instance_type' do expect(mapping(input)).to eq(output) end
      end

      context 'when placement_group is provided by vm_type' do
        let(:input) { { vm_type: { 'placement_group' => 'fake-group' } } }
        let(:output) { { placement: { group_name: 'fake-group' } } }

        it 'maps to placement.group_name' do expect(mapping(input)).to eq(output) end
      end

      describe 'Tenancy options' do
        context 'when tenancy is provided by vm_type, as "dedicated"' do
          let(:input) { { vm_type: { 'tenancy' => 'dedicated' } } }
          let(:output) { { placement: { tenancy: 'dedicated' } } }

          it 'maps to placement.tenancy' do expect(mapping(input)).to eq(output) end
        end

        context 'when tenancy is provided by vm_type, as other than "dedicated"' do
          let(:input) { { vm_type: { 'tenancy' => 'ignored' } } }
          let(:output) { {} }

          it 'is ignored' do expect(mapping(input)).to eq(output) end
        end
      end

      describe 'Key Name options' do
        context 'when key_name is provided by defaults (only)' do
          let(:input) do
            {
              defaults: { 'default_key_name' => 'default-fake-key-name' }
            }
          end
          let(:output) { { key_name: 'default-fake-key-name' } }

          it 'maps key_name from defaults' do expect(mapping(input)).to eq(output) end
        end

        context 'when key_name is provided by defaults and vm_type' do
          let(:input) do
            {
              vm_type: { 'key_name' => 'fake-key-name' },
              defaults: { 'default_key_name' => 'default-fake-key-name' }
            }
          end
          let(:output) { { key_name: 'fake-key-name' } }

          it 'maps key_name from vm_type' do expect(mapping(input)).to eq(output) end
        end
      end

      describe 'IAM instance profile options' do
        context 'when iam_instance_profile is provided by defaults (only)' do
          let(:input) do
            {
              defaults: { 'default_iam_instance_profile' => 'default-fake-iam-profile' }
            }
          end
          let(:output) { { iam_instance_profile: { name: 'default-fake-iam-profile' } } }

          it 'maps iam_instance_profile from defaults' do expect(mapping(input)).to eq(output) end
        end

        context 'when iam_instance_profile is provided by defaults and vm_type' do
          let(:input) do
            {
              vm_type: { 'iam_instance_profile' => 'fake-iam-profile' },
              defaults: { 'default_iam_instance_profile' => 'default-fake-iam-profile' }
            }
          end
          let(:output) { { iam_instance_profile: { name: 'fake-iam-profile' } } }

          it 'maps iam_instance_profile from vm_type' do expect(mapping(input)).to eq(output) end
        end
      end

      describe 'Security Group options' do
        context 'when security_groups is provided by defaults (only)' do
          let(:input) do
            {
              networks_spec: {
                "net1" => {
                  "cloud_properties" => {
                    "subnet" => dynamic_subnet_id,
                  }
                },
              },
              defaults: { 'default_security_groups' => ["sg-11111111", "sg-2-name"] }
            }
          end
          let(:output) do
            {
              network_interfaces: [{
                device_index: 0,
                subnet_id: dynamic_subnet_id,
                groups: ["sg-11111111", "sg-22222222"]
              }]
            }
          end

          it 'maps network_interfaces.first[:groups] from defaults' do expect(mapping(input)).to eq(output) end
        end

        context 'when security_groups is provided by defaults and networks_spec' do
          let(:input) do
            {
              networks_spec: {
                "net1" => {
                  "cloud_properties" => {
                    "security_groups" => ["sg-11111111", "sg-2-name"],
                    "subnet" => dynamic_subnet_id,
                  }
                },
                "net2" => {
                  "cloud_properties" => {
                    "security_groups" => "sg-33333333",
                    "subnet" => dynamic_subnet_id,
                  }
                }
              },
              defaults: { 'default_security_groups' => ["sg-44444444", "sg-5-name"] }
            }
          end
          let(:output) do
            {
              network_interfaces: [{
                device_index: 0,
                subnet_id: dynamic_subnet_id,
                groups: ["sg-11111111", "sg-22222222", "sg-33333333"]
              }]
            }
          end

          it 'maps network_interfaces.first[:groups] from networks_spec' do expect(mapping(input)).to eq(output) end
        end

        context 'when security_groups is provided by defaults, networks_spec, and vm_type' do
          let(:input) do
            {
              vm_type: { 'security_groups' => ["sg-11111111", "sg-2-name"] },
              networks_spec: {
                "net1" => {
                  "cloud_properties" => {
                    "security_groups" => ["sg-33333333", "sg-4-name"],
                    "subnet" => dynamic_subnet_id,
                  }
                },
                "net2" => {
                  "cloud_properties" => {
                    "security_groups" => "sg-55555555",
                    "subnet" => dynamic_subnet_id,
                  }
                }
              },
              defaults: { 'default_security_groups' => ["sg-6-name", "sg-77777777"] }
            }
          end
          let(:output) do
            {
              network_interfaces: [{
                device_index: 0,
                subnet_id: dynamic_subnet_id,
                groups: ["sg-11111111", "sg-22222222"]
              }]
            }
          end

          it 'maps network_interfaces.first[:groups] from vm_type' do expect(mapping(input)).to eq(output) end
        end
      end

      context 'when registry_endpoint is provided' do
        let(:input) { { registry_endpoint: 'example.com' } }
        let(:output) { { user_data: Base64.encode64('{"registry":{"endpoint":"example.com"}}').strip } }

        it 'maps to Base64 encoded user_data.registry.endpoint' do expect(mapping(input)).to eq(output) end
      end

      context 'when dns is provided by networks in networks_spec' do
        let(:input) do
          {
            networks_spec: {
              "net1" => {},
              "net2" => {"dns" => "1.1.1.1"},
              "net3" => {"dns" => "2.2.2.2"}
            }
          }
        end
        let(:output) { { user_data: Base64.encode64('{"dns":{"nameserver":"1.1.1.1"}}').strip } }

        it 'maps to Base64 encoded user_data.dns, from the first matching network' do expect(mapping(input)).to eq(output) end
      end

      describe 'IP address options' do
        context 'when an IP address is provided for explicitly specified manual networks in networks_spec' do
          let(:input) do
            {
              networks_spec: {
                "net1" => {
                  "type" => "dynamic"
                },
                "net2" => {
                  "type" => "manual",
                  "ip" => "1.1.1.1"
                },
                "net3" => {
                  "type" => "manual",
                  "ip" => "2.2.2.2"
                }
              }
            }
          end
          let(:output) do
            {
              network_interfaces: [
                {
                  private_ip_address: '1.1.1.1',
                  device_index: 0
                }
              ]
            }
          end

          it 'maps the first (explicit) manual network IP address to private_ip_address' do
            expect(mapping(input)).to eq(output)
          end
        end

        context 'when an IP address is provided for implicitly specified manual networks in networks_spec' do
          let(:input) do
            {
              networks_spec: {
                "net1" => {
                  "type" => "dynamic"
                },
                "net2" => {
                  "ip" => "1.1.1.1"
                },
                "net3" => {
                  "type" => "manual",
                  "ip" => "2.2.2.2"
                }
              }
            }
          end
          let(:output) do
            {
              network_interfaces: [
                {
                  private_ip_address: '1.1.1.1',
                  device_index: 0
                }
              ]
            }
          end

          it 'maps the first (implicit) manual network IP address to private_ip_address' do
            expect(mapping(input)).to eq(output)
          end
        end

        context 'when associate_public_ip_address is true' do
          let(:input) do
            {
              vm_type: {
                'auto_assign_public_ip' => true
              }
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
      end

      describe 'Subnet options' do
        context 'when subnet is provided by manual (explicit or implicit)' do
          let(:input) do
            {
              networks_spec: {
                "net1" => {
                  "type" => "vip",
                  "cloud_properties" => { "subnet" => "vip-subnet" }
                },
                "net2" => {
                  "cloud_properties" => { "subnet" => manual_subnet_id }
                }
              },
              subnet_az_mapping: {
                manual_subnet_id => "region-1b"
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
              placement: { availability_zone: "region-1b" }
            }
          end

          it 'maps subnet from the first matching network to subnet_id' do
            expect(mapping(input)).to eq(output)
          end
        end

        context 'when subnet is provided by manual (explicit or implicit) or dynamic networks in networks_spec' do
          let(:input) do
            {
              networks_spec: {
                "net1" => {
                  "type" => "dynamic",
                  "cloud_properties" => { "subnet" => dynamic_subnet_id }
                },
                "net2" => {
                  "type" => "manual",
                  "cloud_properties" => { "subnet" => manual_subnet_id }
                }
              },
              subnet_az_mapping: {
                dynamic_subnet_id => "region-1a",
                manual_subnet_id => "region-1b"
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
      end

      describe 'Availability Zone options' do
        context 'when (only) resource pool AZ is provided' do
          let(:input) { { vm_type: { "availability_zone" => "region-1a" } } }
          let(:output) { { placement: { availability_zone: "region-1a" } } }
          it 'maps placement.availability_zone from vm_type' do
            expect(mapping(input)).to eq(output)
          end
        end

        context 'when resource pool AZ, and networks AZs are provided' do
          let(:input) do
            {
              vm_type: {
                "availability_zone" => "region-1a"
              },
              networks_spec: {
                "net1" => {
                  "type" => "dynamic",
                  "cloud_properties" => { "subnet" => dynamic_subnet_id }
                },
              },
              subnet_az_mapping: {
                dynamic_subnet_id => "region-1a"
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
          let(:input) do
            {
              volume_zones: ["region-1a", "region-1a"],
              vm_type: {
                "availability_zone" => "region-1a"
              },
              networks_spec: {
                "net1" => {
                  "type" => "dynamic",
                  "cloud_properties" => { "subnet" => dynamic_subnet_id }
                }
              },
              subnet_az_mapping: {
                dynamic_subnet_id => "region-1a"
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
        let(:input) { { block_device_mappings: ["fake-device"] } }
        let(:output) { { block_device_mappings: ["fake-device"] } }
        it 'passes the mapping through to the output' do
          expect(mapping(input)).to eq(output)
        end
      end

      context 'when a full spec is provided' do
        context 'with security group IDs' do
          let(:input) do
            {
              stemcell_id: "ami-something",
              vm_type: {
                "instance_type" => "fake-instance-type",
                "availability_zone" => "region-1a",
                "key_name" => "fake-key-name",
                "iam_instance_profile" => "fake-iam-profile",
                "security_groups" => ["sg-12345678", "sg-23456789"],
                "tenancy" => "dedicated",

              },
              networks_spec: {
                "net1" => {
                  "type" => "manual",
                  "ip" => "1.1.1.1",
                  "dns" => "8.8.8.8",
                  "cloud_properties" => { "subnet" => manual_subnet_id }
                }
              },
              subnet_az_mapping: {
                dynamic_subnet_id => "region-1a"
              },
              volume_zones: ["region-1a", "region-1a"],
              registry_endpoint: "example.com",
              block_device_mappings: ["fake-device"]
            }
          end
          let(:output) do
            {
              image_id: "ami-something",
              instance_type: "fake-instance-type",
              placement: {
                availability_zone: "region-1a",
                tenancy: "dedicated"
              },
              key_name: "fake-key-name",
              iam_instance_profile: { name: "fake-iam-profile" },
              network_interfaces: [
                {
                  subnet_id: manual_subnet_id,
                  private_ip_address: "1.1.1.1",
                  device_index: 0,
                  groups: ["sg-12345678", "sg-23456789"],
                }
              ],
              user_data: Base64.encode64('{"registry":{"endpoint":"example.com"},"dns":{"nameserver":"8.8.8.8"}}').strip,
              block_device_mappings: ["fake-device"]
            }
          end
          it 'correctly renders the instance params' do
            expect(mapping(input)).to eq(output)
          end
        end
      end
    end

    describe '#validate_required_inputs' do
      it 'raises an exception if any required properties are not provided' do
        required_inputs = [
          'stemcell_id',
          'registry_endpoint',
          'cloud_properties.instance_type',
          'cloud_properties.availability_zone',
          '\(cloud_properties.key_name or defaults.default_key_name\)',
          '\(cloud_properties.security_groups or defaults.default_security_groups\)',
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
      it 'raises an error when provided AZs do not match' do
        instance_param_mapper.manifest_params = {
          volume_zones: ["region-1a", "region-1a"],
          vm_type: {
            "availability_zone" => "region-1a",
          },
          networks_spec: {
            "net1" => {
              "type" => "dynamic",
              "cloud_properties" => { "subnet" => dynamic_subnet_id }
            }
          },
          subnet_az_mapping: {
            dynamic_subnet_id => "region-1b"
          }
        }
        expect {
          instance_param_mapper.validate_availability_zone
        }.to raise_error Bosh::Clouds::CloudError, /can't use multiple availability zones/
      end
    end

    describe '#validate' do
      it 'does not raise an exception on valid input' do
        instance_param_mapper.manifest_params = {
          stemcell_id: "ami-something",
          vm_type: {
            "instance_type" => "fake-instance-type",
            "availability_zone" => "region-1a",
            "key_name" => "fake-key-name",
            "security_groups" => ["sg-12345678"]
          },
          networks_spec: {
            "net1" => {
              "type" => "dynamic",
              "cloud_properties" => { "subnet" => dynamic_subnet_id }
            }
          },
          registry_endpoint: "example.com",
        }
        expect {
          instance_param_mapper.validate
        }.to_not raise_error
      end

      it 'does not raise an exception on valid input and defaults' do
        instance_param_mapper.manifest_params = {
          stemcell_id: "ami-something",
          vm_type: {
            "instance_type" => "fake-instance-type",
            "availability_zone" => "region-1a"
          },
          networks_spec: {
            "net1" => {
              "type" => "dynamic",
              "cloud_properties" => { "subnet" => dynamic_subnet_id }
            }
          },
          registry_endpoint: "example.com",
          defaults: {
            "default_key_name" => "fake-key-name",
            "default_security_groups" => ["sg-12345678"]
          }
        }
        expect {
          instance_param_mapper.validate
        }.to_not raise_error
      end
    end

    private

    def mapping(input)
      instance_param_mapper.manifest_params = input
      instance_param_mapper.instance_params
    end
  end
end
