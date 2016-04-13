require "spec_helper"

module Bosh::AwsCloud
  describe 'InstanceParamMapper' do
    describe '#instance_params' do

      context 'when stemcell_id is provided' do
        let(:input) { { stemcell_id: 'fake-stemcell' } }
        let(:output) { { image_id: 'fake-stemcell' } }

        it 'maps to image_id' do expect(mapping(input)).to eq(output) end
      end

      context 'when instance_type is provided by resource_pool' do
        let(:input) { { resource_pool: { 'instance_type' => 'fake-instance' } } }
        let(:output) { { instance_type: 'fake-instance' } }

        it 'maps to instance_type' do expect(mapping(input)).to eq(output) end
      end

      context 'when placement_group is provided by resource_pool' do
        let(:input) { { resource_pool: { 'placement_group' => 'fake-group' } } }
        let(:output) { { placement: { group_name: 'fake-group' } } }

        it 'maps to placement.group_name' do expect(mapping(input)).to eq(output) end
      end

      describe 'Tenancy options' do
        context 'when tenancy is provided by resource_pool, as "dedicated"' do
          let(:input) { { resource_pool: { 'tenancy' => 'dedicated' } } }
          let(:output) { { placement: { tenancy: 'dedicated' } } }

          it 'maps to placement.tenancy' do expect(mapping(input)).to eq(output) end
        end

        context 'when tenancy is provided by resource_pool, as other than "dedicated"' do
          let(:input) { { resource_pool: { 'tenancy' => 'ignored' } } }
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

        context 'when key_name is provided by defaults and resource_pool' do
          let(:input) do
            {
              resource_pool: { 'key_name' => 'fake-key-name' },
              defaults: { 'default_key_name' => 'default-fake-key-name' }
            }
          end
          let(:output) { { key_name: 'fake-key-name' } }

          it 'maps key_name from resource_pool' do expect(mapping(input)).to eq(output) end
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

        context 'when iam_instance_profile is provided by defaults and resource_pool' do
          let(:input) do
            {
              resource_pool: { 'iam_instance_profile' => 'fake-iam-profile' },
              defaults: { 'default_iam_instance_profile' => 'default-fake-iam-profile' }
            }
          end
          let(:output) { { iam_instance_profile: { name: 'fake-iam-profile' } } }

          it 'maps iam_instance_profile from resource_pool' do expect(mapping(input)).to eq(output) end
        end
      end

      describe 'Security Group options' do
        context 'when security_groups is provided by defaults (only) as ids' do
          let(:input) do
            {
              defaults: { 'default_security_groups' => ["sg-67890123", "sg-78901234"] }
            }
          end
          let(:output) do
            {
              network_interfaces: [{
                device_index: 0,
                groups: ["sg-67890123", "sg-78901234"]
              }]
            }
          end

          it 'maps network_interfaces.first[:groups] from defaults' do expect(mapping(input)).to eq(output) end
        end

        context 'when security_groups is provided by defaults and networks_spec as ids' do
          let(:input) do
            {
              networks_spec: {
                "net1" => {"cloud_properties" => {"security_groups" => ["sg-34567890", "sg-45678901"]}},
                "net2" => {"cloud_properties" => {"security_groups" => "sg-56789012"}}
              },
              defaults: { 'default_security_groups' => ["sg-67890123", "sg-78901234"] }
            }
          end
          let(:output) do
            {
              network_interfaces: [{
                device_index: 0,
                groups: ["sg-34567890", "sg-45678901", "sg-56789012"]
              }]
            }
          end

          it 'maps network_interfaces.first[:groups] from networks_spec' do expect(mapping(input)).to eq(output) end
        end

        context 'when security_groups is provided by defaults, networks_spec, and resource_pool as ids' do
          let(:input) do
            {
              resource_pool: { 'security_groups' => ["sg-12345678", "sg-23456789"] },
              networks_spec: {
                "net1" => {"cloud_properties" => {"security_groups" => ["sg-34567890", "sg-45678901"]}},
                "net2" => {"cloud_properties" => {"security_groups" => "sg-56789012"}}
              },
              defaults: { 'default_security_groups' => ["sg-67890123", "sg-78901234"] }
            }
          end
          let(:output) do
            {
              network_interfaces: [{
                device_index: 0,
                groups: ["sg-12345678", "sg-23456789"]
              }]
            }
          end

          it 'maps network_interfaces.first[:groups] from resource_pool' do expect(mapping(input)).to eq(output) end
        end

        context 'when security_groups is provided by defaults (only) as names' do
          let(:input) do
            {
              defaults: { 'default_security_groups' => ["sg-6-name", "sg-7-name"] },
              sg_name_mapper: sg_name_mapper
            }
          end
          let(:output) do
            {
              network_interfaces: [{
                device_index: 0,
                groups: ["sg-6-id", "sg-7-id"]
              }]
            }
          end

          it 'maps security_groups from defaults' do expect(mapping(input)).to eq(output) end
        end

        context 'when security_groups is provided by defaults and networks_spec as names' do
          let(:input) do
            {
              networks_spec: {
                "net1" => {"cloud_properties" => {"security_groups" => ["sg-3-name", "sg-4-name"]}},
                "net2" => {"cloud_properties" => {"security_groups" => "sg-5-name"}}
              },
              defaults: { 'default_security_groups' => ["sg-6-name", "sg-7-name"] },
              sg_name_mapper: sg_name_mapper
            }
          end

          let(:output) do
            {
              network_interfaces: [{
                device_index: 0,
                groups: ["sg-3-id", "sg-4-id", "sg-5-id"]
              }]
            }
          end

          it 'maps security_groups from networks_spec' do expect(mapping(input)).to eq(output) end
        end

        context 'when security_groups is provided by defaults, networks_spec, and resource_pool as names' do
          let(:input) do
            {
              resource_pool: { 'security_groups' => ["sg-1-name", "sg-2-name"] },
              networks_spec: {
                "net1" => {"cloud_properties" => {"security_groups" => ["sg-3-name", "sg-4-name"]}},
                "net2" => {"cloud_properties" => {"security_groups" => "sg-5-name"}}
              },
              defaults: { 'default_security_groups' => ["sg-6-name", "sg-7-name"] },
              sg_name_mapper: sg_name_mapper
            }
          end
          let(:output) do
            {
              network_interfaces: [{
                device_index: 0,
                groups: ["sg-1-id", "sg-2-id"]
              }]
            }
          end

          it 'maps security_groups from resource_pool' do expect(mapping(input)).to eq(output) end
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
                  "cloud_properties" => { "subnet" => "manual-subnet" }
                }
              },
              subnet_az_mapping: {
                "manual-subnet" => "region-1b"
              }
            }
          end
          let(:output) do
            {
              network_interfaces: [
                {
                  subnet_id: "manual-subnet",
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
                  "cloud_properties" => { "subnet" => "dynamic-subnet" }
                },
                "net2" => {
                  "type" => "manual",
                  "cloud_properties" => { "subnet" => "manual-subnet" }
                }
              },
              subnet_az_mapping: {
                "dynamic-subnet" => "region-1a",
                "manual-subnet" => "region-1b"
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
                  subnet_id: 'dynamic-subnet',
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
          let(:input) { { resource_pool: { "availability_zone" => "region-1a" } } }
          let(:output) { { placement: { availability_zone: "region-1a" } } }
          it 'maps placement.availability_zone from resource_pool' do
            expect(mapping(input)).to eq(output)
          end
        end

        context 'when resource pool AZ, and networks AZs are provided' do
          let(:input) do
            {
              resource_pool: {
                "availability_zone" => "region-1a"
              },
              networks_spec: {
                "net1" => {
                  "type" => "dynamic",
                  "cloud_properties" => { "subnet" => "dynamic-subnet" }
                },
              },
              subnet_az_mapping: {
                "dynamic-subnet" => "region-1a"
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
                  subnet_id: 'dynamic-subnet',
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
              resource_pool: {
                "availability_zone" => "region-1a"
              },
              networks_spec: {
                "net1" => {
                  "type" => "dynamic",
                  "cloud_properties" => { "subnet" => "dynamic-subnet" }
                }
              },
              subnet_az_mapping: {
                "dynamic-subnet" => "region-1a"
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
                  subnet_id: 'dynamic-subnet',
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
              resource_pool: {
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
                  "cloud_properties" => { "subnet" => "manual-subnet" }
                }
              },
              subnet_az_mapping: {
                "dynamic-subnet" => "region-1a"
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
                  subnet_id: "manual-subnet",
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
          'resource_pool.instance_type',
          'resource_pool.availability_zone',
          '\(resource_pool.key_name or defaults.default_key_name\)',
          '\(resource_pool.security_groups or network security_groups or defaults.default_security_groups\)',
          'networks_spec.\[\].cloud_properties.subnet_id'
        ]
        instance_param_mapper = InstanceParamMapper.new

        required_inputs.each do |input_name|
          expect {
            instance_param_mapper.validate_required_inputs
          }.to raise_error(Regexp.new(input_name))
        end
      end
    end

    describe '#validate_security_groups' do
      it 'raises an exception if security groups are a mixture of ids and names' do
        instance_param_mapper = InstanceParamMapper.new

        instance_param_mapper.manifest_params = {
          resource_pool: {
            "security_groups" => ["sg-12345678", "named-sg"]
          },
        }
        expect {
          instance_param_mapper.validate_security_groups
        }.to raise_error Bosh::Clouds::CloudError, 'security group names and ids can not be used together in security groups'
      end
    end

    describe '#validate_availability_zone' do
      it 'raises an error when provided AZs do not match' do
        instance_param_mapper = InstanceParamMapper.new

        instance_param_mapper.manifest_params = {
          volume_zones: ["region-1a", "region-1a"],
          resource_pool: {
            "availability_zone" => "region-1a",
          },
          networks_spec: {
            "net1" => {
              "type" => "dynamic",
              "cloud_properties" => { "subnet" => "dynamic-subnet" }
            }
          },
          subnet_az_mapping: {
            "dynamic-subnet" => "region-1b"
          }
        }
        expect {
          instance_param_mapper.validate_availability_zone
        }.to raise_error Bosh::Clouds::CloudError, /can't use multiple availability zones/
      end
    end

    describe '#validate' do
      it 'does not raise an exception on valid input' do
        instance_param_mapper = InstanceParamMapper.new

        instance_param_mapper.manifest_params = {
          stemcell_id: "ami-something",
          resource_pool: {
            "instance_type" => "fake-instance-type",
            "availability_zone" => "region-1a",
            "key_name" => "fake-key-name",
            "security_groups" => ["sg-12345678"]
          },
          networks_spec: {
            "net1" => {
              "type" => "dynamic",
              "cloud_properties" => { "subnet" => "dynamic-subnet" }
            }
          },
          registry_endpoint: "example.com",
        }
        expect {
          instance_param_mapper.validate
        }.to_not raise_error
      end

      it 'does not raise an exception on valid input and defaults' do
        instance_param_mapper = InstanceParamMapper.new

        instance_param_mapper.manifest_params = {
          stemcell_id: "ami-something",
          resource_pool: {
            "instance_type" => "fake-instance-type",
            "availability_zone" => "region-1a"
          },
          networks_spec: {
            "net1" => {
              "type" => "dynamic",
              "cloud_properties" => { "subnet" => "dynamic-subnet" }
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
      instance_param_mapper = InstanceParamMapper.new
      instance_param_mapper.manifest_params = input
      instance_params = instance_param_mapper.instance_params
    end

    def sg_name_mapper
      Proc.new do |sg_names|
        id_lookup = {
          "sg-1-name" => "sg-1-id",
          "sg-2-name" => "sg-2-id",
          "sg-3-name" => "sg-3-id",
          "sg-4-name" => "sg-4-id",
          "sg-5-name" => "sg-5-id",
          "sg-6-name" => "sg-6-id",
          "sg-7-name" => "sg-7-id"
        }
        sg_names.map { |name| id_lookup[name] }
      end
    end
  end
end
