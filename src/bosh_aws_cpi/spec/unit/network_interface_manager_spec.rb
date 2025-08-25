require 'spec_helper'

module Bosh::AwsCloud
  describe NetworkInterfaceManager do
    let(:logger) { Logger.new('/dev/null') }
    let(:ec2_client) { instance_double(Aws::EC2::Resource) }
    let(:security_group_mapper) { instance_double(SecurityGroupMapper) }
    let(:network_interface_manager) { NetworkInterfaceManager.new(ec2_client, logger, security_group_mapper) }
    
    let(:manual_subnet_id) { 'manual-subnet' }
    let(:dynamic_subnet_id) { 'dynamic-subnet' }
    
    let(:default_options) do
      {
        'aws' => {
          'region' => 'us-east-1',
          'default_key_name' => 'some-key',
          'default_security_groups' => ['baz']
        }
      }
    end
    let(:global_config) do
      instance_double(Bosh::AwsCloud::Config, aws: Bosh::AwsCloud::AwsConfig.new(default_options['aws']))
    end
    let(:vm_cloud_props) do
      Bosh::AwsCloud::VMCloudProps.new(vm_type, global_config)
    end
    let(:vm_type) { {} }
    let(:default_security_groups) { ['sg-default'] }

    before do
      allow(security_group_mapper).to receive(:map_to_ids).and_return(['sg-mapped'])
    end

    describe '#create_network_interfaces' do
      context 'with manual networks' do
        let(:networks_spec) do
          {
            'net1' => {
              'type' => 'manual',
              'ip' => '10.0.0.1',
              'cloud_properties' => { 'subnet' => manual_subnet_id }
            }
          }
        end
        let(:network_cloud_props) do
          Bosh::AwsCloud::NetworkCloudProps.new(networks_spec, global_config)
        end

        it 'creates network interfaces for manual networks' do
          mock_ec2_client = instance_double(Aws::EC2::Client)
          mock_network_interface = instance_double(Aws::EC2::NetworkInterface)
          mock_bosh_ni = instance_double(Bosh::AwsCloud::NetworkInterface)
          
          allow(ec2_client).to receive(:client).and_return(mock_ec2_client)
          allow(ec2_client).to receive(:network_interface).and_return(mock_network_interface)
          allow(ec2_client).to receive(:subnets).and_return([])
          
          expect(mock_ec2_client).to receive(:create_network_interface).with(
            hash_including(subnet_id: manual_subnet_id)
          ).and_return(
            double('response', network_interface: double('ni', network_interface_id: 'eni-123'))
          )
          
          allow(Bosh::AwsCloud::NetworkInterface).to receive(:new).and_return(mock_bosh_ni)
          allow(mock_bosh_ni).to receive(:wait_until_available)
          allow(mock_bosh_ni).to receive(:attach_ip_prefixes)
          allow(mock_bosh_ni).to receive(:add_associate_public_ip_address)
          allow(mock_bosh_ni).to receive(:mac_address).and_return('00:11:22:33:44:55')

          result = network_interface_manager.create_network_interfaces(network_cloud_props, vm_cloud_props, default_security_groups)
          
          expect(result).to be_an(Array)
          expect(result.size).to eq(1)
          expect(result.first).to eq(mock_bosh_ni)
        end
      end

      context 'with dynamic networks' do
        let(:networks_spec) do
          {
            'net1' => {
              'type' => 'dynamic',
              'ip' => '10.0.0.1',
              'cloud_properties' => { 'subnet' => dynamic_subnet_id }
            }
          }
        end
        let(:network_cloud_props) do
          Bosh::AwsCloud::NetworkCloudProps.new(networks_spec, global_config)
        end

        it 'creates network interfaces for dynamic networks' do
          mock_ec2_client = instance_double(Aws::EC2::Client)
          mock_network_interface = instance_double(Aws::EC2::NetworkInterface)
          mock_bosh_ni = instance_double(Bosh::AwsCloud::NetworkInterface)
          
          allow(ec2_client).to receive(:client).and_return(mock_ec2_client)
          allow(ec2_client).to receive(:network_interface).and_return(mock_network_interface)
          allow(ec2_client).to receive(:subnets).and_return([])
          
          allow(mock_ec2_client).to receive(:create_network_interface).and_return(
            double('response', network_interface: double('ni', network_interface_id: 'eni-456'))
          )
          
          allow(Bosh::AwsCloud::NetworkInterface).to receive(:new).and_return(mock_bosh_ni)
          allow(mock_bosh_ni).to receive(:wait_until_available)
          allow(mock_bosh_ni).to receive(:attach_ip_prefixes)
          allow(mock_bosh_ni).to receive(:add_associate_public_ip_address)
          allow(mock_bosh_ni).to receive(:mac_address).and_return('00:11:22:33:44:66')

          result = network_interface_manager.create_network_interfaces(network_cloud_props, vm_cloud_props, default_security_groups)
          
          expect(result).to be_an(Array)
          expect(result.size).to eq(1)
          expect(result.first).to eq(mock_bosh_ni)
        end
      end

      context 'with mixed IPv4 and IPv6 networks in same nic_group' do
        let(:networks_spec) do
          {
            'net1' => {
              'type' => 'manual',
              'ip' => '10.0.0.1',
              'nic_group' => 'mixed-group',
              'cloud_properties' => { 'subnet' => manual_subnet_id }
            },
            'net2' => {
              'type' => 'manual',
              'ip' => '2600::1',
              'nic_group' => 'mixed-group',
              'cloud_properties' => { 'subnet' => manual_subnet_id }
            }
          }
        end
        let(:network_cloud_props) do
          Bosh::AwsCloud::NetworkCloudProps.new(networks_spec, global_config)
        end

        it 'creates single network interface with both IPv4 and IPv6' do
          mock_ec2_client = instance_double(Aws::EC2::Client)
          mock_network_interface = instance_double(Aws::EC2::NetworkInterface)
          mock_bosh_ni = instance_double(Bosh::AwsCloud::NetworkInterface)
          
          allow(ec2_client).to receive(:client).and_return(mock_ec2_client)
          allow(ec2_client).to receive(:network_interface).and_return(mock_network_interface)
          allow(ec2_client).to receive(:subnets).and_return([])
          
          allow(mock_ec2_client).to receive(:create_network_interface).and_return(
            double('response', network_interface: double('ni', network_interface_id: 'eni-789'))
          )
          
          allow(Bosh::AwsCloud::NetworkInterface).to receive(:new).and_return(mock_bosh_ni)
          allow(mock_bosh_ni).to receive(:wait_until_available)
          allow(mock_bosh_ni).to receive(:attach_ip_prefixes)
          allow(mock_bosh_ni).to receive(:add_associate_public_ip_address)
          allow(mock_bosh_ni).to receive(:mac_address).and_return('00:11:22:33:44:77')

          result = network_interface_manager.create_network_interfaces(network_cloud_props, vm_cloud_props, default_security_groups)
          
          expect(result).to be_an(Array)
          expect(result.size).to eq(1)
          expect(result.first).to eq(mock_bosh_ni)
        end
      end

      context 'with multiple separate nic_groups' do
        let(:networks_spec) do
          {
            'net1' => {
              'type' => 'manual',
              'ip' => '10.0.0.1',
              'nic_group' => 'group1',
              'cloud_properties' => { 'subnet' => manual_subnet_id }
            },
            'net2' => {
              'type' => 'manual',
              'ip' => '10.0.0.2',
              'nic_group' => 'group2',
              'cloud_properties' => { 'subnet' => manual_subnet_id }
            }
          }
        end
        let(:network_cloud_props) do
          Bosh::AwsCloud::NetworkCloudProps.new(networks_spec, global_config)
        end

        it 'creates separate network interfaces for each nic_group' do
          mock_ec2_client = instance_double(Aws::EC2::Client)
          mock_network_interface = instance_double(Aws::EC2::NetworkInterface)
          mock_bosh_ni1 = instance_double(Bosh::AwsCloud::NetworkInterface)
          mock_bosh_ni2 = instance_double(Bosh::AwsCloud::NetworkInterface)
          
          allow(ec2_client).to receive(:client).and_return(mock_ec2_client)
          allow(ec2_client).to receive(:network_interface).and_return(mock_network_interface)
          allow(ec2_client).to receive(:subnets).and_return([])
          
          call_count = 0
          allow(mock_ec2_client).to receive(:create_network_interface) do
            call_count += 1
            double('response', network_interface: double('ni', network_interface_id: "eni-#{call_count}00"))
          end
          
          allow(Bosh::AwsCloud::NetworkInterface).to receive(:new).and_return(mock_bosh_ni1, mock_bosh_ni2)
          [mock_bosh_ni1, mock_bosh_ni2].each do |mock_ni|
            allow(mock_ni).to receive(:wait_until_available)
            allow(mock_ni).to receive(:attach_ip_prefixes)
            allow(mock_ni).to receive(:add_associate_public_ip_address)
            allow(mock_ni).to receive(:mac_address).and_return("00:11:22:33:44:#{call_count}#{call_count}")
          end

          result = network_interface_manager.create_network_interfaces(network_cloud_props, vm_cloud_props, default_security_groups)
          
          expect(result).to be_an(Array)
          expect(result.size).to eq(2)
          expect(result).to contain_exactly(mock_bosh_ni1, mock_bosh_ni2)
        end
      end

      context 'with networks using default nic_group (network name)' do
        let(:networks_spec) do
          {
            'default-network' => {
              'type' => 'manual',
              'ip' => '10.0.0.1',
              'cloud_properties' => { 'subnet' => manual_subnet_id }
            },
            'other-network' => {
              'type' => 'manual',
              'ip' => '10.0.0.2',
              'cloud_properties' => { 'subnet' => manual_subnet_id }
            }
          }
        end
        let(:network_cloud_props) do
          Bosh::AwsCloud::NetworkCloudProps.new(networks_spec, global_config)
        end

        it 'creates separate network interfaces using network names as nic_groups' do
          mock_ec2_client = instance_double(Aws::EC2::Client)
          mock_network_interface = instance_double(Aws::EC2::NetworkInterface)
          mock_bosh_ni1 = instance_double(Bosh::AwsCloud::NetworkInterface)
          mock_bosh_ni2 = instance_double(Bosh::AwsCloud::NetworkInterface)
          
          allow(ec2_client).to receive(:client).and_return(mock_ec2_client)
          allow(ec2_client).to receive(:network_interface).and_return(mock_network_interface)
          allow(ec2_client).to receive(:subnets).and_return([])
          
          call_count = 0
          allow(mock_ec2_client).to receive(:create_network_interface) do
            call_count += 1
            double('response', network_interface: double('ni', network_interface_id: "eni-default-#{call_count}"))
          end
          
          allow(Bosh::AwsCloud::NetworkInterface).to receive(:new).and_return(mock_bosh_ni1, mock_bosh_ni2)
          [mock_bosh_ni1, mock_bosh_ni2].each do |mock_ni|
            allow(mock_ni).to receive(:wait_until_available)
            allow(mock_ni).to receive(:attach_ip_prefixes)
            allow(mock_ni).to receive(:add_associate_public_ip_address)
            allow(mock_ni).to receive(:mac_address).and_return("00:11:22:33:55:#{call_count}#{call_count}")
          end

          result = network_interface_manager.create_network_interfaces(network_cloud_props, vm_cloud_props, default_security_groups)
          
          expect(result).to be_an(Array)
          expect(result.size).to eq(2)
          expect(result).to contain_exactly(mock_bosh_ni1, mock_bosh_ni2)
        end
      end

      context 'with mix of manual and dynamic networks' do
        let(:networks_spec) do
          {
            'manual-net' => {
              'type' => 'manual',
              'ip' => '10.0.0.1',
              'cloud_properties' => { 'subnet' => manual_subnet_id }
            },
            'dynamic-net' => {
              'type' => 'dynamic',
              'cloud_properties' => { 'subnet' => dynamic_subnet_id }
            }
          }
        end
        let(:network_cloud_props) do
          Bosh::AwsCloud::NetworkCloudProps.new(networks_spec, global_config)
        end

        it 'creates network interfaces for both manual and dynamic networks' do
          mock_ec2_client = instance_double(Aws::EC2::Client)
          mock_network_interface = instance_double(Aws::EC2::NetworkInterface)
          mock_bosh_ni1 = instance_double(Bosh::AwsCloud::NetworkInterface)
          mock_bosh_ni2 = instance_double(Bosh::AwsCloud::NetworkInterface)
          
          allow(ec2_client).to receive(:client).and_return(mock_ec2_client)
          allow(ec2_client).to receive(:network_interface).and_return(mock_network_interface)
          allow(ec2_client).to receive(:subnets).and_return([])
          
          call_count = 0
          allow(mock_ec2_client).to receive(:create_network_interface) do
            call_count += 1
            double('response', network_interface: double('ni', network_interface_id: "eni-mixed-#{call_count}"))
          end
          
          allow(Bosh::AwsCloud::NetworkInterface).to receive(:new).and_return(mock_bosh_ni1, mock_bosh_ni2)
          [mock_bosh_ni1, mock_bosh_ni2].each do |mock_ni|
            allow(mock_ni).to receive(:wait_until_available)
            allow(mock_ni).to receive(:attach_ip_prefixes)
            allow(mock_ni).to receive(:add_associate_public_ip_address)
            allow(mock_ni).to receive(:mac_address).and_return("00:11:22:44:55:#{call_count}#{call_count}")
          end

          result = network_interface_manager.create_network_interfaces(network_cloud_props, vm_cloud_props, default_security_groups)
          
          expect(result).to be_an(Array)
          expect(result.size).to eq(2)
          expect(result).to contain_exactly(mock_bosh_ni1, mock_bosh_ni2)
        end
      end

      context 'with complex nic_group combinations' do
        let(:networks_spec) do
          {
            'ipv4-only' => {
              'type' => 'manual',
              'ip' => '10.0.0.1',
              'nic_group' => 'shared-group',
              'cloud_properties' => { 'subnet' => manual_subnet_id }
            },
            'ipv6-only' => {
              'type' => 'manual',
              'ip' => '2600::1',
              'nic_group' => 'shared-group',
              'cloud_properties' => { 'subnet' => manual_subnet_id }
            },
            'separate-manual' => {
              'type' => 'manual',
              'ip' => '10.0.0.3',
              'nic_group' => 'isolated-group',
              'cloud_properties' => { 'subnet' => manual_subnet_id }
            },
            'dynamic-default' => {
              'type' => 'dynamic',
              'cloud_properties' => { 'subnet' => dynamic_subnet_id }
            }
          }
        end
        let(:network_cloud_props) do
          Bosh::AwsCloud::NetworkCloudProps.new(networks_spec, global_config)
        end

        it 'creates appropriate network interfaces for complex combinations' do
          mock_ec2_client = instance_double(Aws::EC2::Client)
          mock_network_interface = instance_double(Aws::EC2::NetworkInterface)
          mock_bosh_ni1 = instance_double(Bosh::AwsCloud::NetworkInterface)
          mock_bosh_ni2 = instance_double(Bosh::AwsCloud::NetworkInterface)
          mock_bosh_ni3 = instance_double(Bosh::AwsCloud::NetworkInterface)
          
          allow(ec2_client).to receive(:client).and_return(mock_ec2_client)
          allow(ec2_client).to receive(:network_interface).and_return(mock_network_interface)
          allow(ec2_client).to receive(:subnets).and_return([])
          
          call_count = 0
          allow(mock_ec2_client).to receive(:create_network_interface) do
            call_count += 1
            double('response', network_interface: double('ni', network_interface_id: "eni-complex-#{call_count}"))
          end
          
          allow(Bosh::AwsCloud::NetworkInterface).to receive(:new).and_return(mock_bosh_ni1, mock_bosh_ni2, mock_bosh_ni3)
          [mock_bosh_ni1, mock_bosh_ni2, mock_bosh_ni3].each do |mock_ni|
            allow(mock_ni).to receive(:wait_until_available)
            allow(mock_ni).to receive(:attach_ip_prefixes)
            allow(mock_ni).to receive(:add_associate_public_ip_address)
            allow(mock_ni).to receive(:mac_address).and_return("00:11:22:66:77:#{call_count}#{call_count}")
          end

          result = network_interface_manager.create_network_interfaces(network_cloud_props, vm_cloud_props, default_security_groups)
          
          expect(result).to be_an(Array)
          expect(result.size).to eq(3) # shared-group (1), isolated-group (1), dynamic-default (1)
          expect(result).to contain_exactly(mock_bosh_ni1, mock_bosh_ni2, mock_bosh_ni3)
        end
      end

      context 'error scenarios' do
        context 'when networks in same nic_group have different subnets' do
          let(:networks_spec) do
            {
              'net1' => {
                'type' => 'manual',
                'ip' => '10.0.0.1',
                'nic_group' => 'conflicted-group',
                'cloud_properties' => { 'subnet' => manual_subnet_id }
              },
              'net2' => {
                'type' => 'manual',
                'ip' => '10.0.0.2',
                'nic_group' => 'conflicted-group',
                'cloud_properties' => { 'subnet' => 'different-subnet' }
              }
            }
          end
          let(:network_cloud_props) do
            Bosh::AwsCloud::NetworkCloudProps.new(networks_spec, global_config)
          end

          it 'raises an error about subnet mismatch' do
            expect {
              network_interface_manager.create_network_interfaces(network_cloud_props, vm_cloud_props, default_security_groups)
            }.to raise_error(Bosh::Clouds::CloudError, /Networks in nic_group.*have different subnet ids/)
          end
        end

        context 'when only dynamic networks are specified' do
          let(:networks_spec) do
            {
              'dynamic1' => {
                'type' => 'dynamic',
                'cloud_properties' => { 'subnet' => dynamic_subnet_id }
              },
              'dynamic2' => {
                'type' => 'dynamic',
                'cloud_properties' => { 'subnet' => 'another-dynamic-subnet' }
              }
            }
          end
          let(:network_cloud_props) do
            Bosh::AwsCloud::NetworkCloudProps.new(networks_spec, global_config)
          end

          it 'creates network interface only for first dynamic network' do
            mock_ec2_client = instance_double(Aws::EC2::Client)
            mock_network_interface = instance_double(Aws::EC2::NetworkInterface)
            mock_bosh_ni = instance_double(Bosh::AwsCloud::NetworkInterface)
            
            allow(ec2_client).to receive(:client).and_return(mock_ec2_client)
            allow(ec2_client).to receive(:network_interface).and_return(mock_network_interface)
            allow(ec2_client).to receive(:subnets).and_return([])
            
            allow(mock_ec2_client).to receive(:create_network_interface).and_return(
              double('response', network_interface: double('ni', network_interface_id: 'eni-dynamic-only'))
            )
            
            allow(Bosh::AwsCloud::NetworkInterface).to receive(:new).and_return(mock_bosh_ni)
            allow(mock_bosh_ni).to receive(:wait_until_available)
            allow(mock_bosh_ni).to receive(:attach_ip_prefixes)
            allow(mock_bosh_ni).to receive(:add_associate_public_ip_address)
            allow(mock_bosh_ni).to receive(:mac_address).and_return('00:11:22:33:99:99')

            result = network_interface_manager.create_network_interfaces(network_cloud_props, vm_cloud_props, default_security_groups)
            
            expect(result).to be_an(Array)
            expect(result.size).to eq(1) # Only first dynamic network creates interface
            expect(result.first).to eq(mock_bosh_ni)
          end
        end
      end
    end

    describe '#validate_subnet_az_mapping' do
      context 'when all subnets are in same availability zone' do
        it 'does not raise an error' do
          mock_subnet1 = double('subnet1', availability_zone: 'us-east-1a')
          mock_subnet2 = double('subnet2', availability_zone: 'us-east-1a')
          
          allow(ec2_client).to receive(:subnets).and_return([mock_subnet1, mock_subnet2])
          
          nic_group1 = instance_double(Bosh::AwsCloud::NicGroup, subnet_id: 'subnet-1')
          nic_group2 = instance_double(Bosh::AwsCloud::NicGroup, subnet_id: 'subnet-2')
          nic_groups = { 'group1' => nic_group1, 'group2' => nic_group2 }
          
          expect {
            network_interface_manager.send(:validate_subnet_az_mapping, nic_groups)
          }.not_to raise_error
        end
      end

      context 'when subnets are in different availability zones' do
        it 'raises an error' do
          mock_subnet1 = double('subnet1', availability_zone: 'us-east-1a')
          mock_subnet2 = double('subnet2', availability_zone: 'us-east-1b')
          
          allow(ec2_client).to receive(:subnets).and_return([mock_subnet1, mock_subnet2])
          
          nic_group1 = instance_double(Bosh::AwsCloud::NicGroup, subnet_id: 'subnet-1')
          nic_group2 = instance_double(Bosh::AwsCloud::NicGroup, subnet_id: 'subnet-2')
          nic_groups = { 'group1' => nic_group1, 'group2' => nic_group2 }
          
          expect {
            network_interface_manager.send(:validate_subnet_az_mapping, nic_groups)
          }.to raise_error(Bosh::Clouds::CloudError, /All nic groups must be in the same availability zone/)
        end
      end
    end

    describe '#provision_network_interfaces' do
      let(:nic_group) { instance_double(Bosh::AwsCloud::NicGroup) }
      let(:nic_groups) { { 'group1' => nic_group } }
      
      before do
        allow(nic_group).to receive(:subnet_id).and_return('subnet-123')
        allow(nic_group).to receive(:manual_network?).and_return(true)
        allow(nic_group).to receive(:has_ipv4_address?).and_return(true)
        allow(nic_group).to receive(:has_ipv6_address?).and_return(false)
        allow(nic_group).to receive(:ipv4_address).and_return('10.0.0.1')
        allow(nic_group).to receive(:prefixes).and_return(nil)
        allow(nic_group).to receive(:assign_mac_address)
      end

      it 'provisions network interfaces for nic groups' do
        mock_ec2_client = instance_double(Aws::EC2::Client)
        mock_network_interface = instance_double(Aws::EC2::NetworkInterface)
        mock_bosh_ni = instance_double(Bosh::AwsCloud::NetworkInterface)
        
        allow(ec2_client).to receive(:client).and_return(mock_ec2_client)
        allow(ec2_client).to receive(:network_interface).and_return(mock_network_interface)
        
        allow(mock_ec2_client).to receive(:create_network_interface).and_return(
          double('response', network_interface: double('ni', network_interface_id: 'eni-provision'))
        )
        
        allow(Bosh::AwsCloud::NetworkInterface).to receive(:new).and_return(mock_bosh_ni)
        allow(mock_bosh_ni).to receive(:wait_until_available)
        allow(mock_bosh_ni).to receive(:attach_ip_prefixes)
        allow(mock_bosh_ni).to receive(:add_associate_public_ip_address)
        allow(mock_bosh_ni).to receive(:mac_address).and_return('00:11:22:33:44:88')

        network_cloud_props = instance_double(Bosh::AwsCloud::NetworkCloudProps)
        allow(network_cloud_props).to receive(:security_groups).and_return([])
        
        result = network_interface_manager.send(:provision_network_interfaces, nic_groups, network_cloud_props, vm_cloud_props, default_security_groups)
        
        expect(result).to be_an(Array)
        expect(result.size).to eq(1)
        expect(result.first).to eq(mock_bosh_ni)
      end

      context 'when security groups are missing' do
        before do
          allow(security_group_mapper).to receive(:map_to_ids).and_return([])
        end

        it 'raises an error' do
          network_cloud_props = instance_double(Bosh::AwsCloud::NetworkCloudProps)
          allow(network_cloud_props).to receive(:security_groups).and_return([])
          
          expect {
            network_interface_manager.send(:provision_network_interfaces, nic_groups, network_cloud_props, vm_cloud_props, default_security_groups)
          }.to raise_error(Bosh::Clouds::CloudError, /Missing security groups/)
        end
      end
    end

    describe 'Security Group options' do
      let(:networks_spec) do
        {
          'net1' => {
            'ip' => '10.0.0.1',
            'type' => 'dynamic',
            'cloud_properties' => {
              'subnet' => dynamic_subnet_id
            }
          }
        }
      end
      let(:network_cloud_props) do
        Bosh::AwsCloud::NetworkCloudProps.new(networks_spec, global_config)
      end

      context 'when security_groups is provided by defaults' do
        let(:default_security_groups) { %w(sg-11111111 sg-2-name) }

        it 'uses default security groups' do
          expect(security_group_mapper).to receive(:map_to_ids).with(default_security_groups, dynamic_subnet_id)
          
          mock_ec2_client = instance_double(Aws::EC2::Client)
          mock_network_interface = instance_double(Aws::EC2::NetworkInterface)
          mock_bosh_ni = instance_double(Bosh::AwsCloud::NetworkInterface)
          
          allow(ec2_client).to receive(:client).and_return(mock_ec2_client)
          allow(ec2_client).to receive(:network_interface).and_return(mock_network_interface)
          allow(ec2_client).to receive(:subnets).and_return([])
          
          allow(mock_ec2_client).to receive(:create_network_interface).and_return(
            double('response', network_interface: double('ni', network_interface_id: 'eni-sg-test'))
          )
          
          allow(Bosh::AwsCloud::NetworkInterface).to receive(:new).and_return(mock_bosh_ni)
          allow(mock_bosh_ni).to receive(:wait_until_available)
          allow(mock_bosh_ni).to receive(:attach_ip_prefixes)
          allow(mock_bosh_ni).to receive(:add_associate_public_ip_address)
          allow(mock_bosh_ni).to receive(:mac_address).and_return('00:11:22:33:44:99')

          network_interface_manager.create_network_interfaces(network_cloud_props, vm_cloud_props, default_security_groups)
        end
      end
    end

    describe 'DNS configuration' do
      let(:mock_ec2_client) { instance_double(Aws::EC2::Client) }
      let(:mock_network_interface) { instance_double(Aws::EC2::NetworkInterface) }
      
      before do
        allow(ec2_client).to receive(:client).and_return(mock_ec2_client)
        allow(ec2_client).to receive(:network_interface).and_return(mock_network_interface)
        allow(ec2_client).to receive(:subnets).and_return([])
      end

      context 'when dns is provided by manual networks in networks_spec' do
        let(:networks_spec) do
          {
            'net1' => {
              'type' => 'manual',
              'ip' => '10.0.0.1',
              'cloud_properties' => { 'subnet' => manual_subnet_id }
            },
            'net2' => {
              'type' => 'manual',
              'ip' => '10.0.0.2',
              'dns' => '1.1.1.1',
              'cloud_properties' => { 'subnet' => manual_subnet_id }
            }
          }
        end
        let(:network_cloud_props) do
          Bosh::AwsCloud::NetworkCloudProps.new(networks_spec, global_config)
        end

        it 'creates network interfaces and preserves DNS configuration in manual networks' do
          mock_bosh_ni1 = instance_double(Bosh::AwsCloud::NetworkInterface)
          mock_bosh_ni2 = instance_double(Bosh::AwsCloud::NetworkInterface)
          
          call_count = 0
          allow(mock_ec2_client).to receive(:create_network_interface) do
            call_count += 1
            double('response', network_interface: double('ni', network_interface_id: "eni-dns-#{call_count}"))
          end
          
          allow(Bosh::AwsCloud::NetworkInterface).to receive(:new).and_return(mock_bosh_ni1, mock_bosh_ni2)
          [mock_bosh_ni1, mock_bosh_ni2].each do |mock_ni|
            allow(mock_ni).to receive(:wait_until_available)
            allow(mock_ni).to receive(:attach_ip_prefixes)
            allow(mock_ni).to receive(:add_associate_public_ip_address)
            allow(mock_ni).to receive(:mac_address).and_return("00:11:22:33:dns:#{call_count}")
          end

          result = network_interface_manager.create_network_interfaces(network_cloud_props, vm_cloud_props, default_security_groups)
          
          expect(result).to be_an(Array)
          expect(result.size).to eq(2)
          
          # Verify that DNS configuration is preserved in network_cloud_props for manual networks
          net1 = network_cloud_props.networks.find { |n| n.name == 'net1' }
          net2 = network_cloud_props.networks.find { |n| n.name == 'net2' }
          
          expect(net1.dns).to be_nil
          expect(net2.dns).to eq('1.1.1.1')
        end
      end

      context 'when dns is provided by multiple networks in networks_spec' do
        let(:networks_spec) do
          {
            'net1' => {
              'type' => 'manual',
              'ip' => '10.0.0.1',
              'cloud_properties' => { 'subnet' => manual_subnet_id }
            },
            'net2' => {
              'type' => 'manual',
              'ip' => '10.0.0.2',
              'dns' => '1.1.1.1',
              'cloud_properties' => { 'subnet' => manual_subnet_id }
            },
            'net3' => {
              'type' => 'manual',
              'ip' => '10.0.0.3',
              'dns' => '2.2.2.2',
              'cloud_properties' => { 'subnet' => manual_subnet_id }
            }
          }
        end
        let(:network_cloud_props) do
          Bosh::AwsCloud::NetworkCloudProps.new(networks_spec, global_config)
        end

        it 'creates network interfaces with DNS configuration preserved' do
          mock_bosh_ni1 = instance_double(Bosh::AwsCloud::NetworkInterface)
          mock_bosh_ni2 = instance_double(Bosh::AwsCloud::NetworkInterface)
          mock_bosh_ni3 = instance_double(Bosh::AwsCloud::NetworkInterface)
          
          call_count = 0
          allow(mock_ec2_client).to receive(:create_network_interface) do
            call_count += 1
            double('response', network_interface: double('ni', network_interface_id: "eni-dns-#{call_count}"))
          end
          
          allow(Bosh::AwsCloud::NetworkInterface).to receive(:new).and_return(mock_bosh_ni1, mock_bosh_ni2, mock_bosh_ni3)
          [mock_bosh_ni1, mock_bosh_ni2, mock_bosh_ni3].each do |mock_ni|
            allow(mock_ni).to receive(:wait_until_available)
            allow(mock_ni).to receive(:attach_ip_prefixes)
            allow(mock_ni).to receive(:add_associate_public_ip_address)
            allow(mock_ni).to receive(:mac_address).and_return("00:11:22:33:dns:#{call_count}")
          end

          result = network_interface_manager.create_network_interfaces(network_cloud_props, vm_cloud_props, default_security_groups)
          
          expect(result).to be_an(Array)
          expect(result.size).to eq(3)
          expect(result).to contain_exactly(mock_bosh_ni1, mock_bosh_ni2, mock_bosh_ni3)
          
          # Verify that DNS configuration is preserved in network_cloud_props
          expect(network_cloud_props.networks.find { |n| n.name == 'net2' }.dns).to eq('1.1.1.1')
          expect(network_cloud_props.networks.find { |n| n.name == 'net3' }.dns).to eq('2.2.2.2')
        end
      end

      context 'when networks have different DNS configurations in same nic_group' do
        let(:networks_spec) do
          {
            'net1' => {
              'type' => 'manual',
              'ip' => '10.0.0.1',
              'nic_group' => 'shared-dns-group',
              'dns' => '8.8.8.8',
              'cloud_properties' => { 'subnet' => manual_subnet_id }
            },
            'net2' => {
              'type' => 'manual',
              'ip' => '2600::1',
              'nic_group' => 'shared-dns-group',
              'dns' => '1.1.1.1',
              'cloud_properties' => { 'subnet' => manual_subnet_id }
            }
          }
        end
        let(:network_cloud_props) do
          Bosh::AwsCloud::NetworkCloudProps.new(networks_spec, global_config)
        end

        it 'creates network interface with mixed DNS configurations' do
          mock_bosh_ni = instance_double(Bosh::AwsCloud::NetworkInterface)
          
          allow(mock_ec2_client).to receive(:create_network_interface).and_return(
            double('response', network_interface: double('ni', network_interface_id: 'eni-mixed-dns'))
          )
          
          allow(Bosh::AwsCloud::NetworkInterface).to receive(:new).and_return(mock_bosh_ni)
          allow(mock_bosh_ni).to receive(:wait_until_available)
          allow(mock_bosh_ni).to receive(:attach_ip_prefixes)
          allow(mock_bosh_ni).to receive(:add_associate_public_ip_address)
          allow(mock_bosh_ni).to receive(:mac_address).and_return('00:11:22:33:mixed:dns')

          result = network_interface_manager.create_network_interfaces(network_cloud_props, vm_cloud_props, default_security_groups)
          
          expect(result).to be_an(Array)
          expect(result.size).to eq(1)
          expect(result.first).to eq(mock_bosh_ni)
          
          # Verify that DNS configuration is preserved for both networks
          expect(network_cloud_props.networks.find { |n| n.name == 'net1' }.dns).to eq('8.8.8.8')
          expect(network_cloud_props.networks.find { |n| n.name == 'net2' }.dns).to eq('1.1.1.1')
        end
      end

      context 'when some networks have DNS and others do not' do
        let(:networks_spec) do
          {
            'no-dns-net' => {
              'type' => 'manual',
              'ip' => '10.0.0.1',
              'cloud_properties' => { 'subnet' => manual_subnet_id }
            },
            'with-dns-net' => {
              'type' => 'manual',
              'ip' => '10.0.0.2',
              'dns' => '9.9.9.9',
              'cloud_properties' => { 'subnet' => manual_subnet_id }
            }
          }
        end
        let(:network_cloud_props) do
          Bosh::AwsCloud::NetworkCloudProps.new(networks_spec, global_config)
        end

        it 'handles mixed DNS configurations correctly' do
          mock_bosh_ni1 = instance_double(Bosh::AwsCloud::NetworkInterface)
          mock_bosh_ni2 = instance_double(Bosh::AwsCloud::NetworkInterface)
          
          call_count = 0
          allow(mock_ec2_client).to receive(:create_network_interface) do
            call_count += 1
            double('response', network_interface: double('ni', network_interface_id: "eni-mixed-dns-#{call_count}"))
          end
          
          allow(Bosh::AwsCloud::NetworkInterface).to receive(:new).and_return(mock_bosh_ni1, mock_bosh_ni2)
          [mock_bosh_ni1, mock_bosh_ni2].each do |mock_ni|
            allow(mock_ni).to receive(:wait_until_available)
            allow(mock_ni).to receive(:attach_ip_prefixes)
            allow(mock_ni).to receive(:add_associate_public_ip_address)
            allow(mock_ni).to receive(:mac_address).and_return("00:11:22:33:opt:#{call_count}")
          end

          result = network_interface_manager.create_network_interfaces(network_cloud_props, vm_cloud_props, default_security_groups)
          
          expect(result).to be_an(Array)
          expect(result.size).to eq(2)
          expect(result).to contain_exactly(mock_bosh_ni1, mock_bosh_ni2)
          
          # Verify DNS configurations
          no_dns_network = network_cloud_props.networks.find { |n| n.name == 'no-dns-net' }
          with_dns_network = network_cloud_props.networks.find { |n| n.name == 'with-dns-net' }
          
          expect(no_dns_network.dns).to be_nil
          expect(with_dns_network.dns).to eq('9.9.9.9')
        end
      end
    end
  end
end