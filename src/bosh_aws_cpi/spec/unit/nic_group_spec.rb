require 'spec_helper'

module Bosh::AwsCloud
  describe NicGroup do
    # Helper method to create network doubles with default values
    def create_network(double_name, options = {})
      defaults = {
        name: double_name.downcase.gsub(/\s+/, '-'),
        type: 'manual',
        subnet: 'subnet-123',
        ip: nil,
        prefix: nil
      }
      attrs = defaults.merge(options)
      
      network = double(double_name, attrs)
      allow(network).to receive(:respond_to?).with(:ip).and_return(attrs[:ip] != nil)
      allow(network).to receive(:respond_to?).with(:mac=).and_return(attrs.key?(:'mac='))
      network
    end

    let(:manual_network_ipv4) { create_network('manual-ipv4', ip: '10.0.0.1') }
    let(:manual_network_ipv6) { create_network('manual-ipv6', ip: '2600::1') }
    let(:manual_network_ipv4_prefix) { create_network('manual-ipv4-prefix', ip: '10.0.0.0', prefix: '24') }
    let(:manual_network_ipv6_prefix) { create_network('manual-ipv6-prefix', ip: '2600::', prefix: '64') }
    let(:dynamic_network) { create_network('dynamic-net', type: 'dynamic', subnet: 'subnet-456', ip: nil) }
    let(:network_with_mac) { create_network('manual-with-mac', ip: '10.0.0.2', 'mac=': nil) }

    describe '#initialize' do
      context 'with empty networks array' do
        let(:nic_group) { NicGroup.new('test-group') }
        
        it 'creates nic group without validation' do
          expect(nic_group.name).to eq('test-group')
          expect(nic_group.networks).to be_empty
          %i[ipv4_address ipv6_address ipv4_prefix ipv6_prefix].each do |attr|
            expect(nic_group.send(attr)).to be_nil
          end
        end
      end

      context 'with networks array provided' do
        let(:nic_group) { NicGroup.new('test-group', [manual_network_ipv4]) }
        
        it 'creates nic group and validates configuration' do
          expect(nic_group.name).to eq('test-group')
          expect(nic_group.networks).to eq([manual_network_ipv4])
          expect(nic_group.ipv4_address).to eq('10.0.0.1')
          expect(nic_group.ipv6_address).to be_nil
        end
      end
    end

    describe '#add_network' do
      let(:nic_group) { NicGroup.new('test-group') }

      it 'adds network and validates configuration' do
        nic_group.add_network(manual_network_ipv4)
        nic_group.validate_and_extract_ip_config
        
        expect(nic_group.networks).to eq([manual_network_ipv4])
        expect(nic_group.ipv4_address).to eq('10.0.0.1')
      end

      it 'adds multiple networks to same group' do
        nic_group.add_network(manual_network_ipv4)
        nic_group.add_network(manual_network_ipv6)
        nic_group.validate_and_extract_ip_config
        
        expect(nic_group.networks).to eq([manual_network_ipv4, manual_network_ipv6])
        expect(nic_group.ipv4_address).to eq('10.0.0.1')
        expect(nic_group.ipv6_address).to eq('2600::1')
      end

      context 'when networks have different subnets' do
        let(:different_subnet_network) do
          double('ManualNetwork',
            name: 'different-subnet',
            type: 'manual',
            subnet: 'subnet-999',
            ip: '10.0.0.3',
            prefix: nil
          )
        end

        it 'raises an error' do
          nic_group.add_network(manual_network_ipv4)
          nic_group.add_network(different_subnet_network)
          
          expect {
            nic_group.validate_and_extract_ip_config
          }.to raise_error(Bosh::Clouds::CloudError, /Networks in nic_group.*have different subnet ids/)
        end
      end
    end

    describe 'basic accessors' do
      let(:nic_group_with_networks) { NicGroup.new('test-group', [manual_network_ipv4, manual_network_ipv6]) }
      let(:empty_nic_group) { NicGroup.new('test-group') }

      describe '#subnet_id' do
        it 'returns subnet from first network' do
          expect(nic_group_with_networks.subnet_id).to eq('subnet-123')
        end

        it 'returns nil when no networks' do
          expect(empty_nic_group.subnet_id).to be_nil
        end
      end

      describe '#first_network' do
        it 'returns first network' do
          expect(nic_group_with_networks.first_network).to eq(manual_network_ipv4)
        end

        it 'returns nil when no networks' do
          expect(empty_nic_group.first_network).to be_nil
        end
      end

      describe '#network_names' do
        it 'returns array of network names' do
          expect(nic_group_with_networks.network_names).to eq(['manual-ipv4', 'manual-ipv6'])
        end

        it 'returns empty array when no networks' do
          expect(empty_nic_group.network_names).to eq([])
        end
      end
    end

    describe 'network type checking' do
      let(:manual_nic_group) { NicGroup.new('manual-group', [manual_network_ipv4]) }
      let(:dynamic_nic_group) { NicGroup.new('dynamic-group', [dynamic_network]) }
      let(:empty_nic_group) { NicGroup.new('empty-group') }

      describe '#manual_network?' do
        it 'returns true when first network is manual' do
          expect(manual_nic_group.manual_network?).to be true
        end

        it 'returns false when first network is dynamic' do
          expect(dynamic_nic_group.manual_network?).to be false
        end

        it 'returns false when no networks' do
          expect(empty_nic_group.manual_network?).to be false
        end
      end

      describe '#dynamic_network?' do
        it 'returns true when first network is dynamic' do
          expect(dynamic_nic_group.dynamic_network?).to be true
        end

        it 'returns false when first network is manual' do
          expect(manual_nic_group.dynamic_network?).to be false
        end

        it 'returns false when no networks' do
          expect(empty_nic_group.dynamic_network?).to be false
        end
      end
    end

    describe 'IP address detection' do
      let(:ipv4_group) { NicGroup.new('ipv4-group', [manual_network_ipv4]) }
      let(:ipv6_group) { NicGroup.new('ipv6-group', [manual_network_ipv6]) }
      let(:mixed_group) { NicGroup.new('mixed-group', [manual_network_ipv4, manual_network_ipv6]) }

      describe 'presence checks' do
        it 'detects IPv4 addresses correctly' do
          expect(ipv4_group.has_ipv4_address?).to be true
          expect(ipv6_group.has_ipv4_address?).to be false
          expect(mixed_group.has_ipv4_address?).to be true
        end

        it 'detects IPv6 addresses correctly' do
          expect(ipv4_group.has_ipv6_address?).to be false
          expect(ipv6_group.has_ipv6_address?).to be true
          expect(mixed_group.has_ipv6_address?).to be true
        end
      end

      describe 'address extraction' do
        it 'extracts IPv4 addresses' do
          expect(ipv4_group.ipv4_address).to eq('10.0.0.1')
          expect(ipv6_group.ipv4_address).to be_nil
        end

        it 'extracts IPv6 addresses' do
          expect(ipv6_group.ipv6_address).to eq('2600::1')
          expect(ipv4_group.ipv6_address).to be_nil
        end
      end
    end

    describe 'IP prefix detection' do
      let(:ipv4_prefix_group) { NicGroup.new('ipv4-prefix-group', [manual_network_ipv4_prefix]) }
      let(:ipv6_prefix_group) { NicGroup.new('ipv6-prefix-group', [manual_network_ipv6_prefix]) }
      let(:mixed_prefix_group) { NicGroup.new('mixed-prefix-group', [manual_network_ipv4_prefix, manual_network_ipv6_prefix]) }
      let(:address_only_group) { NicGroup.new('address-only-group', [manual_network_ipv4]) }

      describe 'prefix presence checks' do
        it 'detects IPv4 prefixes correctly' do
          expect(ipv4_prefix_group.has_ipv4_prefix?).to be true
          expect(address_only_group.has_ipv4_prefix?).to be false
        end

        it 'detects IPv6 prefixes correctly' do
          expect(ipv6_prefix_group.has_ipv6_prefix?).to be true
          expect(address_only_group.has_ipv6_prefix?).to be false
        end
      end

      describe 'prefix extraction' do
        it 'extracts IPv4 prefixes' do
          expect(ipv4_prefix_group.ipv4_prefix).to eq({ address: '10.0.0.0', prefix: '24' })
          expect(address_only_group.ipv4_prefix).to be_nil
        end

        it 'extracts IPv6 prefixes' do
          expect(ipv6_prefix_group.ipv6_prefix).to eq({ address: '2600::', prefix: '64' })
          expect(address_only_group.ipv6_prefix).to be_nil
        end
      end

      describe '#prefixes' do
        it 'returns hash with both IPv4 and IPv6 prefixes' do
          expect(mixed_prefix_group.prefixes).to eq({
            ipv4: { address: '10.0.0.0', prefix: '24' },
            ipv6: { address: '2600::', prefix: '64' }
          })
        end

        it 'returns hash with only IPv4 prefix' do
          expect(ipv4_prefix_group.prefixes).to eq({
            ipv4: { address: '10.0.0.0', prefix: '24' }
          })
        end

        it 'returns hash with only IPv6 prefix' do
          expect(ipv6_prefix_group.prefixes).to eq({
            ipv6: { address: '2600::', prefix: '64' }
          })
        end

        it 'returns nil when no prefixes' do
          expect(address_only_group.prefixes).to be_nil
        end
      end
    end

    describe '#assign_mac_address' do
      it 'assigns MAC address to networks that support it' do
        mac_address = '00:11:22:33:44:55'
        nic_group = NicGroup.new('test-group', [network_with_mac])
        
        expect(network_with_mac).to receive(:mac=).with(mac_address)
        nic_group.assign_mac_address(mac_address)
      end

      it 'skips networks that do not support MAC assignment' do
        mac_address = '00:11:22:33:44:55'
        nic_group = NicGroup.new('test-group', [manual_network_ipv4])
        
        expect { nic_group.assign_mac_address(mac_address) }.not_to raise_error
      end

      it 'assigns MAC to multiple networks' do
        mac_address = '00:11:22:33:44:55'
        network_with_mac_2 = create_network('manual-with-mac-2', ip: '10.0.0.3', 'mac=': nil)
        
        nic_group = NicGroup.new('test-group', [network_with_mac, network_with_mac_2])
        
        expect(network_with_mac).to receive(:mac=).with(mac_address)
        expect(network_with_mac_2).to receive(:mac=).with(mac_address)
        
        nic_group.assign_mac_address(mac_address)
      end
    end

    describe 'complex scenarios' do
      it 'extracts both IPv4 and IPv6 addresses from mixed networks' do
        nic_group = NicGroup.new('mixed-group', [manual_network_ipv4, manual_network_ipv6])
        
        expect(nic_group.ipv4_address).to eq('10.0.0.1')
        expect(nic_group.ipv6_address).to eq('2600::1')
        expect(nic_group.has_ipv4_address?).to be true
        expect(nic_group.has_ipv6_address?).to be true
      end

      it 'extracts first occurrence of each IP type' do
        ipv4_addr_2 = create_network('manual-ipv4-2', ip: '10.0.0.2')
        networks = [manual_network_ipv4, manual_network_ipv4_prefix, ipv4_addr_2]
        nic_group = NicGroup.new('mixed-group', networks)
        
        expect(nic_group.ipv4_address).to eq('10.0.0.1') # First regular address
        expect(nic_group.ipv4_prefix).to eq({ address: '10.0.0.0', prefix: '24' }) # First prefix
      end

      context 'with multiple NICs: 1 IPv6 and 2 IPv4 addresses' do
        let(:ipv4_addr_1) { create_network('ipv4-1', ip: '10.0.0.10') }
        let(:ipv4_addr_2) { create_network('ipv4-2', ip: '10.0.0.20') }
        let(:ipv6_addr) { create_network('ipv6-1', ip: '2600::100') }

        it 'accepts multiple networks with same subnet and extracts first of each IP type' do
          networks = [ipv4_addr_1, ipv6_addr, ipv4_addr_2]
          
          expect { NicGroup.new('multi-nic-group', networks) }.not_to raise_error
          
          nic_group = NicGroup.new('multi-nic-group', networks)
          expect(nic_group.ipv4_address).to eq('10.0.0.10')
          expect(nic_group.ipv6_address).to eq('2600::100')
          expect(nic_group.networks.size).to eq(3)
          expect(nic_group.network_names).to eq(['ipv4-1', 'ipv6-1', 'ipv4-2'])
        end
        
        it 'uses first IPv4 address when multiple present' do
          ipv4_first = create_network('ipv4-first', ip: '10.0.0.1')
          ipv4_second = create_network('ipv4-second', ip: '10.0.0.99')
          
          nic_group = NicGroup.new('first-wins-group', [ipv4_first, ipv4_second])
          
          expect(nic_group.ipv4_address).to eq('10.0.0.1')
          expect(nic_group.ipv4_address).not_to eq('10.0.0.99')
        end
      end

      it 'handles dynamic networks without ip method' do
        allow(dynamic_network).to receive(:respond_to?).with(:ip).and_return(false)
        
        expect { NicGroup.new('dynamic-group', [dynamic_network]) }.not_to raise_error
        
        nic_group = NicGroup.new('dynamic-group', [dynamic_network])
        expect(nic_group.ipv4_address).to be_nil
        expect(nic_group.ipv6_address).to be_nil
      end

      it 'raises error when networks have no subnet' do
        network_no_subnet = create_network('no-subnet', subnet: nil, ip: '10.0.0.1')
        
        expect {
          NicGroup.new('no-subnet-group', [network_no_subnet])
        }.to raise_error(Bosh::Clouds::CloudError, /Networks in nic_group.*have different subnet ids.*or probably none of them have any subnet id defined/)
      end
    end

    describe 'edge cases' do
      it 'treats /32 IPv4 prefix as regular address' do
        ipv4_host_prefix = create_network('ipv4-host', ip: '10.0.0.1', prefix: '32')
        nic_group = NicGroup.new('host-group', [ipv4_host_prefix])
        
        expect(nic_group.ipv4_address).to eq('10.0.0.1')
        expect(nic_group.ipv4_prefix).to be_nil
      end

      it 'treats /128 IPv6 prefix as regular address' do
        ipv6_host_prefix = create_network('ipv6-host', ip: '2600::1', prefix: '128')
        nic_group = NicGroup.new('host-group', [ipv6_host_prefix])
        
        expect(nic_group.ipv6_address).to eq('2600::1')
        expect(nic_group.ipv6_prefix).to be_nil
      end
    end
  end
end
