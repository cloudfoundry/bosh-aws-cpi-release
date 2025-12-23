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
          end
        end
      end
    end
  end
end
