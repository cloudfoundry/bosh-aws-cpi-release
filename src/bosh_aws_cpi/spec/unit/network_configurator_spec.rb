# Copyright (c) 2009-2012 VMware, Inc.

require 'spec_helper'

describe Bosh::AwsCloud::NetworkConfigurator do
  let(:aws_config) do
    instance_double(Bosh::AwsCloud::AwsConfig)
  end
  let(:global_config) do
    instance_double(Bosh::AwsCloud::Config, aws: aws_config)
  end
  let(:dynamic) { { 'type' => 'dynamic' } }
  let(:manual) { { 'type' => 'manual', 'cloud_properties' => { 'subnet' => 'sn-xxxxxxxx' }} }
  let(:vip) { { 'type' => 'vip' } }
  let(:networks_spec) { {} }
  let(:network_cloud_props) do
    Bosh::AwsCloud::NetworkCloudProps.new(networks_spec, global_config)
  end

  def set_security_groups(spec, security_groups)
    spec['cloud_properties'] = {
        'security_groups' => security_groups
    }
  end

  describe '#initialize' do
    let(:networks_spec) do
      {
        'network1' => vip,
        'network2' => vip
      }
    end

    it 'should raise an error if multiple vip networks are defined' do
      expect {
        Bosh::AwsCloud::NetworkConfigurator.new(network_cloud_props)
      }.to raise_error Bosh::Clouds::CloudError, "More than one vip network for 'network2'"
    end

    it 'should raise an error if an illegal network type is used' do
      networks_spec['network1'] = { 'type' => 'foo' }

      expect {
        Bosh::AwsCloud::NetworkConfigurator.new(network_cloud_props)
      }.to raise_error Bosh::Clouds::CloudError, "Invalid network type 'foo' for AWS, " \
                        "can only handle 'dynamic', 'vip', or 'manual' network types"
    end
  end

  describe '#configure' do
    let(:ec2_resource) { instance_double(Aws::EC2::Resource) }
    let(:ec2_client) { instance_double(Aws::EC2::Client) }
    let(:instance) { instance_double(Bosh::AwsCloud::Instance) }

    describe 'without vip' do
      context 'and associated elastic ip' do
        let(:networks_spec) do
          {
            'network1' => dynamic
          }
        end

        it 'should disassociate elastic ip' do
          expect(instance).to receive(:elastic_ip).and_return(double('elastic ip'))
          expect(instance).to receive(:id).and_return('i-xxxxxxxx')
          expect(instance).to receive(:disassociate_elastic_ip)

          Bosh::AwsCloud::NetworkConfigurator.new(network_cloud_props).configure(ec2_resource, instance)
        end
      end

      context 'and with NO associated elastic ip' do
        let(:networks_spec) do
          {
            'network1' => dynamic
          }
        end

        it 'should no-op' do
          expect(instance).to receive(:elastic_ip).and_return(nil)
          expect(instance).not_to receive(:disassociate_elastic_ip)

          Bosh::AwsCloud::NetworkConfigurator.new(network_cloud_props).configure(ec2_resource, instance)
        end
      end

      context 'with vip' do
        context 'when no IP is provided' do
          let(:networks_spec) do
            {
              'network1' => vip
            }
          end

          it 'should raise error' do
            expect {
              Bosh::AwsCloud::NetworkConfigurator.new(network_cloud_props).configure(ec2_resource, instance)
            }.to raise_error(/No IP provided for vip network 'network1'/)
          end
        end

        context 'when IP is provided' do
          let(:vip_public_ip) { '1.2.3.4' }
          let(:vip) do
            {
              'type' => 'vip',
              'ip' => vip_public_ip
            }
          end
          let(:networks_spec) do
            {
              'network1' => vip
            }
          end
          let(:describe_addresses_arguments) do
            {
              public_ips: [vip_public_ip],
              filters: [
                {
                  name: 'domain',
                  values: ['vpc']
                }
              ]
            }
          end

          let(:describe_addresses_response) do
            instance_double(Aws::EC2::Types::DescribeAddressesResult, addresses: response_addresses)
          end

          before do
            allow(ec2_resource).to receive(:client).and_return(ec2_client)
            allow(instance).to receive(:id).and_return('i-xxxxxxxx')
          end

          context 'and Elastic/Public IP is found' do
            let(:elastic_ip) { instance_double(Aws::EC2::Types::Address) }
            let(:response_addresses) { [elastic_ip] }

            it 'should associate Elastic/Public IP to the instance' do
              primary_nic = create_nic_mock(0, 'eni-12345678')
              
              setup_vip_mocks(ec2_client, elastic_ip, describe_addresses_arguments, describe_addresses_response)
              mock_describe_instances(ec2_client, 'i-xxxxxxxx', [primary_nic])
              
              expect(ec2_client).to receive(:associate_address).with(
                network_interface_id: 'eni-12345678',
                allocation_id: 'allocation-id'
              )

              Bosh::AwsCloud::NetworkConfigurator.new(network_cloud_props).configure(ec2_resource, instance)
            end
          end

          context 'but user does not own the Elastic/Public IP' do
            let(:response_addresses) { [] }

            it 'should raise error' do
              expect(ec2_client).to receive(:describe_addresses)
                .with(describe_addresses_arguments).and_return(describe_addresses_response)

              expect {
                Bosh::AwsCloud::NetworkConfigurator.new(network_cloud_props).configure(ec2_resource, instance)
              }.to raise_error(/Elastic IP with VPC scope not found with address '#{vip_public_ip}'/)
            end
          end

          context 'with multiple network interfaces' do
            let(:elastic_ip) { instance_double(Aws::EC2::Types::Address) }
            let(:response_addresses) { [elastic_ip] }

            it 'should associate Elastic IP to primary NIC (device_index 0)' do
              primary_nic = create_nic_mock(0, 'eni-primary')
              secondary_nic = create_nic_mock(1, nil)
              
              setup_vip_mocks(ec2_client, elastic_ip, describe_addresses_arguments, describe_addresses_response)
              mock_describe_instances(ec2_client, 'i-xxxxxxxx', [secondary_nic, primary_nic])
              
              expect(ec2_client).to receive(:associate_address).with(
                network_interface_id: 'eni-primary',
                allocation_id: 'allocation-id'
              )

              Bosh::AwsCloud::NetworkConfigurator.new(network_cloud_props).configure(ec2_resource, instance)
            end

            it 'should handle multiple NICs in any order' do
              primary_nic = create_nic_mock(0, 'eni-primary')
              secondary_nic = create_nic_mock(1, nil)
              
              setup_vip_mocks(ec2_client, elastic_ip, describe_addresses_arguments, describe_addresses_response)
              mock_describe_instances(ec2_client, 'i-xxxxxxxx', [primary_nic, secondary_nic])
              
              expect(ec2_client).to receive(:associate_address).with(
                network_interface_id: 'eni-primary',
                allocation_id: 'allocation-id'
              )

              Bosh::AwsCloud::NetworkConfigurator.new(network_cloud_props).configure(ec2_resource, instance)
            end

            it 'should retry describe_instances on transient errors and succeed' do
              primary_nic = create_nic_mock(0, 'eni-primary')
              
              setup_vip_mocks(ec2_client, elastic_ip, describe_addresses_arguments, describe_addresses_response)
              
              # Simulate transient error on first call, success on second
              instance_data = instance_double(Aws::EC2::Types::Instance, network_interfaces: [primary_nic])
              reservation = instance_double(Aws::EC2::Types::Reservation, instances: [instance_data])
              response = instance_double(Aws::EC2::Types::DescribeInstancesResult, reservations: [reservation])
              
              expect(ec2_client).to receive(:describe_instances).with(instance_ids: ['i-xxxxxxxx'])
                .and_raise(Aws::EC2::Errors::ServiceError.new(nil, 'Service error'))
                .ordered
              expect(ec2_client).to receive(:describe_instances).with(instance_ids: ['i-xxxxxxxx'])
                .and_return(response)
                .ordered
              
              expect(ec2_client).to receive(:associate_address).with(
                network_interface_id: 'eni-primary',
                allocation_id: 'allocation-id'
              )

              Bosh::AwsCloud::NetworkConfigurator.new(network_cloud_props).configure(ec2_resource, instance)
            end

            it 'should raise error when no primary NIC found with helpful message' do
              secondary_nic = create_nic_mock(1, nil)
              tertiary_nic = create_nic_mock(2, nil)
              
              setup_vip_mocks(ec2_client, elastic_ip, describe_addresses_arguments, describe_addresses_response)
              mock_describe_instances(ec2_client, 'i-xxxxxxxx', [secondary_nic, tertiary_nic])
              
              expect {
                Bosh::AwsCloud::NetworkConfigurator.new(network_cloud_props).configure(ec2_resource, instance)
              }.to raise_error(Bosh::Clouds::CloudError, /Could not find network interface with device_index 0.*device indexes: 1, 2/)
            end

            it 'should retry describe_addresses on transient errors and succeed' do
              primary_nic = create_nic_mock(0, 'eni-primary')
              
              expect(elastic_ip).to receive(:allocation_id).and_return('allocation-id')
              
              # Simulate transient error on first call, success on second
              expect(ec2_client).to receive(:describe_addresses)
                .with(describe_addresses_arguments)
                .and_raise(Aws::EC2::Errors::RequestLimitExceeded.new(nil, 'Request limit exceeded'))
                .ordered
              expect(ec2_client).to receive(:describe_addresses)
                .with(describe_addresses_arguments)
                .and_return(describe_addresses_response)
                .ordered
              
              mock_describe_instances(ec2_client, 'i-xxxxxxxx', [primary_nic])
              
              expect(ec2_client).to receive(:associate_address).with(
                network_interface_id: 'eni-primary',
                allocation_id: 'allocation-id'
              )

              Bosh::AwsCloud::NetworkConfigurator.new(network_cloud_props).configure(ec2_resource, instance)
            end
          end

          context 'with nic_group configuration' do
            let(:elastic_ip) { instance_double(Aws::EC2::Types::Address) }
            let(:response_addresses) { [elastic_ip] }

            context 'when vip network has nic_group 0' do
              let(:spec) do
                {
                  'network1' => {
                    'type' => 'manual',
                    'ip' => '10.0.0.10',
                    'netmask' => '255.255.255.0',
                    'nic_group' => '0',
                    'cloud_properties' => {
                      'subnet' => 'subnet-xxxxxxxx'
                    }
                  },
                  'vip' => {
                    'type' => 'vip',
                    'ip' => vip_public_ip,
                    'nic_group' => '0'
                  }
                }
              end
              let(:networks_spec) { spec }

              it 'should associate Elastic IP to primary NIC (device_index 0)' do
                primary_nic = create_nic_mock(0, 'eni-primary')
                secondary_nic = create_nic_mock(1, 'eni-secondary')
                
                setup_vip_mocks(ec2_client, elastic_ip, describe_addresses_arguments, describe_addresses_response)
                mock_describe_instances(ec2_client, 'i-xxxxxxxx', [primary_nic, secondary_nic])
                
                expect(ec2_client).to receive(:associate_address).with(
                  network_interface_id: 'eni-primary',
                  allocation_id: 'allocation-id'
                )

                Bosh::AwsCloud::NetworkConfigurator.new(network_cloud_props).configure(ec2_resource, instance)
              end
            end

            context 'when vip network has nic_group for secondary NIC' do
              let(:spec) do
                {
                  'network1' => {
                    'type' => 'manual',
                    'ip' => '10.0.0.10',
                    'netmask' => '255.255.255.0',
                    'nic_group' => '0',
                    'cloud_properties' => {
                      'subnet' => 'subnet-xxxxxxxx'
                    }
                  },
                  'network2' => {
                    'type' => 'manual',
                    'ip' => '10.1.0.10',
                    'netmask' => '255.255.255.0',
                    'nic_group' => '1',
                    'cloud_properties' => {
                      'subnet' => 'subnet-yyyyyyyy'
                    }
                  },
                  'vip' => {
                    'type' => 'vip',
                    'ip' => vip_public_ip,
                    'nic_group' => '1'
                  }
                }
              end
              let(:networks_spec) { spec }

              it 'should associate Elastic IP to secondary NIC (device_index 1)' do
                primary_nic = create_nic_mock(0, 'eni-primary')
                secondary_nic = create_nic_mock(1, 'eni-secondary')
                
                setup_vip_mocks(ec2_client, elastic_ip, describe_addresses_arguments, describe_addresses_response)
                mock_describe_instances(ec2_client, 'i-xxxxxxxx', [primary_nic, secondary_nic])
                
                expect(ec2_client).to receive(:associate_address).with(
                  network_interface_id: 'eni-secondary',
                  allocation_id: 'allocation-id'
                )

                Bosh::AwsCloud::NetworkConfigurator.new(network_cloud_props).configure(ec2_resource, instance)
              end
            end

            context 'when vip network has nic_group that does not exist' do
              let(:spec) do
                {
                  'network1' => {
                    'type' => 'manual',
                    'ip' => '10.0.0.10',
                    'netmask' => '255.255.255.0',
                    'nic_group' => '0',
                    'cloud_properties' => {
                      'subnet' => 'subnet-xxxxxxxx'
                    }
                  },
                  'vip' => {
                    'type' => 'vip',
                    'ip' => vip_public_ip,
                    'nic_group' => '999'
                  }
                }
              end
              let(:networks_spec) { spec }

              it 'should default to primary NIC (device_index 0)' do
                primary_nic = create_nic_mock(0, 'eni-primary')
                secondary_nic = create_nic_mock(1, 'eni-secondary')
                
                setup_vip_mocks(ec2_client, elastic_ip, describe_addresses_arguments, describe_addresses_response)
                mock_describe_instances(ec2_client, 'i-xxxxxxxx', [primary_nic, secondary_nic])
                
                expect(ec2_client).to receive(:associate_address).with(
                  network_interface_id: 'eni-primary',
                  allocation_id: 'allocation-id'
                )

                Bosh::AwsCloud::NetworkConfigurator.new(network_cloud_props).configure(ec2_resource, instance)
              end
            end

            context 'when vip network uses string integer nic_group' do
              let(:spec) do
                {
                  'network1' => {
                    'type' => 'manual',
                    'ip' => '10.0.0.10',
                    'netmask' => '255.255.255.0',
                    'nic_group' => '0',
                    'cloud_properties' => {
                      'subnet' => 'subnet-xxxxxxxx'
                    }
                  },
                  'vip' => {
                    'type' => 'vip',
                    'ip' => vip_public_ip,
                    'nic_group' => '0'
                  }
                }
              end
              let(:networks_spec) { spec }

              it 'should convert string integer to device_index' do
                primary_nic = create_nic_mock(0, 'eni-primary')
                secondary_nic = create_nic_mock(1, 'eni-secondary')
                
                setup_vip_mocks(ec2_client, elastic_ip, describe_addresses_arguments, describe_addresses_response)
                mock_describe_instances(ec2_client, 'i-xxxxxxxx', [primary_nic, secondary_nic])
                
                expect(ec2_client).to receive(:associate_address).with(
                  network_interface_id: 'eni-primary',
                  allocation_id: 'allocation-id'
                )

                Bosh::AwsCloud::NetworkConfigurator.new(network_cloud_props).configure(ec2_resource, instance)
              end
            end

            context 'when using non-contiguous nic_groups' do
              let(:spec) do
                {
                  'network1' => {
                    'type' => 'manual',
                    'ip' => '10.0.0.10',
                    'netmask' => '255.255.255.0',
                    'nic_group' => '0',
                    'cloud_properties' => {
                      'subnet' => 'subnet-xxxxxxxx'
                    }
                  },
                  'network2' => {
                    'type' => 'manual',
                    'ip' => '10.1.0.10',
                    'netmask' => '255.255.255.0',
                    'nic_group' => '5',
                    'cloud_properties' => {
                      'subnet' => 'subnet-yyyyyyyy'
                    }
                  },
                  'network3' => {
                    'type' => 'manual',
                    'ip' => '10.2.0.10',
                    'netmask' => '255.255.255.0',
                    'nic_group' => '10',
                    'cloud_properties' => {
                      'subnet' => 'subnet-zzzzzzzz'
                    }
                  },
                  'vip' => {
                    'type' => 'vip',
                    'ip' => vip_public_ip,
                    'nic_group' => '5'
                  }
                }
              end
              let(:networks_spec) { spec }

              it 'should match nic_group 5 to device_index 1' do
                nic0 = create_nic_mock(0, 'eni-0')
                nic1 = create_nic_mock(1, 'eni-1')
                nic2 = create_nic_mock(2, 'eni-2')
                
                setup_vip_mocks(ec2_client, elastic_ip, describe_addresses_arguments, describe_addresses_response)
                mock_describe_instances(ec2_client, 'i-xxxxxxxx', [nic0, nic1, nic2])
                
                expect(ec2_client).to receive(:associate_address).with(
                  network_interface_id: 'eni-1',
                  allocation_id: 'allocation-id'
                )

                Bosh::AwsCloud::NetworkConfigurator.new(network_cloud_props).configure(ec2_resource, instance)
              end
            end
          end
        end
      end
    end
  end
end
