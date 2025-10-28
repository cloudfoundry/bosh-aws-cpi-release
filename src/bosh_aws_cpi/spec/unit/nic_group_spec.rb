require 'spec_helper'

module Bosh::AwsCloud
  describe NicGroup do
    let(:manual_network_ipv4) { manual_network('manual-ipv4', {'ip' => '10.0.0.1', 'cloud_properties' => { 'subnet' => 'subnet_id' }})}
    let(:manual_network_ipv6) { manual_network('manual-ipv6', {'ip' => '2001:db8::1', 'cloud_properties' => { 'subnet' => 'subnet_id' }})}
    let(:manual_network_ipv6_prefix) { manual_network('manual-ipv6', {'ip' => '2001:db8:0000:0001::', 'prefix' => '80', 'cloud_properties' => { 'subnet' => 'subnet_id' }})}
    let(:manual_network_ipv4_prefix) { manual_network('manual-ipv6', {'ip' => '10.0.0.16', 'prefix' => '28', 'cloud_properties' => { 'subnet' => 'subnet_id' }})}
    let(:manual_network_ipv4_with_nic_group) { manual_network('manual-ipv4', {'nic_group' => '1', 'ip' => '10.0.0.1', 'cloud_properties' => { 'subnet' => 'subnet_id' }})}
    let(:manual_network_ipv4_same_nic_group_different_subnet_id) { manual_network('manual-ipv4', {'nic_group' => '1', 'ip' => '10.0.0.1', 'cloud_properties' => { 'subnet' => 'subnet_id_different' }})}

    describe '#initialize' do
      context 'with empty networks array' do
        let(:nic_group) { NicGroup.new('test-group') }

        it 'creates nic group without validation' do
          expect(nic_group.name).to eq('test-group')
          expect(nic_group.networks).to be_empty
        end
      end

      context 'with networks array provided' do
        context 'when one network with an ipv4 address is provided' do
          let(:nic_group) { NicGroup.new('test-group', [manual_network_ipv4]) }

          it 'creates nic group and sets ipv4 address' do
            expect(nic_group.name).to eq('test-group')
            expect(nic_group.networks).to eq([manual_network_ipv4])
            expect(nic_group.ipv4_address).to eq('10.0.0.1')
            expect(nic_group.ipv6_address).to be_nil
          end
        end

        context 'when one network with an ipv6 address is provided' do
          let(:nic_group) { NicGroup.new('test-group', [manual_network_ipv6]) }

          it 'creates nic group and sets ipv4 address' do
            expect(nic_group.name).to eq('test-group')
            expect(nic_group.networks).to eq([manual_network_ipv6])
            expect(nic_group.ipv6_address).to eq('2001:db8::1')
            expect(nic_group.ipv4_address).to be_nil
          end
        end

        context 'when all possible networks (ipv4, ipv6, ipv4 prefix and ipv6 prefix) are provided' do
          let(:nic_group) { NicGroup.new('test-group', [manual_network_ipv4, manual_network_ipv6, manual_network_ipv4_prefix, manual_network_ipv6_prefix]) }

          it 'creates nic group and sets all ip addresses and prefixes' do
            expect(nic_group.name).to eq('test-group')
            expect(nic_group.networks).to eq([manual_network_ipv4, manual_network_ipv6, manual_network_ipv4_prefix, manual_network_ipv6_prefix])
            expect(nic_group.ipv6_address).to eq('2001:db8::1')
            expect(nic_group.ipv4_address).to eq('10.0.0.1')
            prefixes = nic_group.prefixes
            expect(prefixes[:ipv4][:address]).to eq('10.0.0.16')
            expect(prefixes[:ipv4][:prefix]).to eq('28')
            expect(prefixes[:ipv6][:address]).to eq('2001:db8:0000:0001::')
            expect(prefixes[:ipv6][:prefix]).to eq('80')
          end
        end

        context 'when only a network with a prefix is provided' do
          it 'raises an error' do
            expect {
              NicGroup.new('test-group', [manual_network_ipv4_prefix])
            }.to raise_error(Bosh::Clouds::CloudError, "Could not find a single ip address for nic group 'test-group' and a prefix network can only be a secondary network.")
          end
        end
      end
    end

    describe '#subnet_id' do
      context 'it provides the subnet id of a nic group' do
        let(:nic_group) { NicGroup.new('test-group', [manual_network_ipv4]) }

        it 'returns the subnet id of the first network' do
          expect(nic_group.subnet_id).to eq('subnet_id')
        end
      end
    end

    describe '#manual?' do
      context 'if a nic group is manual' do
        let(:nic_group) { NicGroup.new('test-group', [manual_network_ipv4]) }

        it 'returns true for manual and false for dynamic' do
          expect(nic_group.manual?).to be_truthy
          expect(nic_group.dynamic?).to be_falsey
        end
      end
    end

    describe '#dynamic?' do
      context 'if a nic group is dynamic' do
        let(:nic_group) { NicGroup.new('test-group', [dynamic_network('dynamic-network', 'cloud_properties' => { 'subnet' => 'subnet_id' })]) }

        it 'returns true for dynamic and false for manual' do
          expect(nic_group.manual?).to be_falsey
          expect(nic_group.dynamic?).to be_truthy
        end
      end
    end

    describe '#assign_mac_address' do
      let(:nic_group) { NicGroup.new('test-group', [manual_network_ipv4, manual_network_ipv6]) }

      it 'assigns the mac address to all networks in the nic_group' do
        nic_group.assign_mac_address('00:11:22:33:44:55')
        nic_group.networks.each do |network|
          expect(network.mac).to eq('00:11:22:33:44:55')
        end
      end
    end

    def manual_network(name, options = {})
      network_settings = {
        type: 'manual'
      }
      network_settings = network_settings.merge(options)
      Bosh::AwsCloud::NetworkCloudProps::Network.create(name, network_settings)
    end

    def dynamic_network(name, options = {})
      network_settings = {
        'type' => 'dynamic'
      }
      network_settings = network_settings.merge(options)
      Bosh::AwsCloud::NetworkCloudProps::Network.create(name, network_settings)
    end
  end
end