require 'spec_helper'

module Bosh::AwsCloud
  describe NicGroup do
    let(:manual_network_ipv4) { manual_network('manual-ipv4', {'ip' => '10.0.0.1', 'cloud_properties' => { 'subnet' => 'subnet_id' }})}
    let(:manual_network_ipv6) { manual_network('manual-ipv6', {'ip' => '2001:db8::1', 'cloud_properties' => { 'subnet' => 'subnet_id' }})}
    let(:manual_network_ipv6_prefix) { manual_network('manual-ipv6', {'ip' => '2001:db8:0000:0001::', 'prefix' => '80', 'cloud_properties' => { 'subnet' => 'subnet_id' }})}
    let(:manual_network_ipv4_prefix) { manual_network('manual-ipv6', {'ip' => '10.0.0.16', 'prefix' => '28', 'cloud_properties' => { 'subnet' => 'subnet_id' }})}
    let(:manual_network_ipv4_with_nic_group) { manual_network('manual-ipv4', {'nic_group' => '1', 'ip' => '10.0.0.1', 'cloud_properties' => { 'subnet' => 'subnet_id' }})}
    let(:manual_network_ipv4_same_nic_group_different_subnet_id) { manual_network('manual-ipv4', {'nic_group' => '1', 'ip' => '10.0.0.1', 'cloud_properties' => { 'subnet' => 'subnet_id_different' }})}
    let(:manual_network_primary_ipv6) { manual_network('ipv6-primary', {'ip' => '2001:db8::1', 'cloud_properties' => { 'subnet' => 'subnet_id', 'primary_ipv6' => true }})}
    let(:manual_network_primary_ipv6_with_ipv4) { manual_network('ipv6-primary-with-v4', {'ip' => '2001:db8::1', 'cloud_properties' => { 'subnet' => 'subnet_id', 'primary_ipv6' => true }})}

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

        context 'when a network has primary_ipv6: true in cloud_properties' do
          let(:nic_group) { NicGroup.new('test-group', [manual_network_primary_ipv6]) }

          it 'sets primary_ipv6? to true and sets ipv6_address' do
            expect(nic_group.primary_ipv6?).to be true
            expect(nic_group.ipv6_address).to eq('2001:db8::1')
            expect(nic_group.ipv4_address).to be_nil
          end
        end

        context 'when a network does not have primary_ipv6 in cloud_properties' do
          let(:nic_group) { NicGroup.new('test-group', [manual_network_ipv6]) }

          it 'sets primary_ipv6? to false' do
            expect(nic_group.primary_ipv6?).to be false
          end
        end

        context 'when primary_ipv6: true is combined with an IPv4 address (dual-stack)' do
          it 'is allowed and sets both addresses with primary_ipv6? true' do
            dual_stack = manual_network('dual', {'nic_group' => 'test-group', 'ip' => '10.0.0.1', 'cloud_properties' => { 'subnet' => 'subnet_id' }})
            primary6 = manual_network('p6', {'nic_group' => 'test-group', 'ip' => '2001:db8::1', 'cloud_properties' => { 'subnet' => 'subnet_id', 'primary_ipv6' => true }})
            nic_group = NicGroup.new('test-group', [dual_stack, primary6])
            expect(nic_group.primary_ipv6?).to be true
            expect(nic_group.ipv4_address).to eq('10.0.0.1')
            expect(nic_group.ipv6_address).to eq('2001:db8::1')
          end
        end

        context 'when primary_ipv6: true is set but no IPv6 address is provided' do
          it 'raises an error' do
            ipv4_primary6 = manual_network('v4-primary6', {'nic_group' => 'test-group', 'ip' => '10.0.0.1', 'cloud_properties' => { 'subnet' => 'subnet_id', 'primary_ipv6' => true }})
            expect {
              NicGroup.new('test-group', [ipv4_primary6])
            }.to raise_error(Bosh::Clouds::CloudError, /primary_ipv6: true but no IPv6 address was specified/)
          end
        end

        context 'when a later network is flagged primary_ipv6 but an earlier IPv6 network provides the address' do
          it 'raises an error rather than sending a mismatched address' do
            first_ipv6 = manual_network('first-v6', {'nic_group' => 'test-group', 'ip' => '2001:db8::1', 'cloud_properties' => { 'subnet' => 'subnet_id' }})
            primary6 = manual_network('primary-v6', {'nic_group' => 'test-group', 'ip' => '2001:db8::2', 'cloud_properties' => { 'subnet' => 'subnet_id', 'primary_ipv6' => true }})
            expect {
              NicGroup.new('test-group', [first_ipv6, primary6])
            }.to raise_error(Bosh::Clouds::CloudError, /primary_ipv6.*but the selected IPv6 address is '2001:db8::1'/)
          end
        end

        context 'when the primary_ipv6 network provides the selected IPv6 address (ordering-independent)' do
          it 'uses the flagged address even when it is not first' do
            other_ipv4 = manual_network('v4', {'nic_group' => 'test-group', 'ip' => '10.0.0.1', 'cloud_properties' => { 'subnet' => 'subnet_id' }})
            primary6 = manual_network('primary-v6', {'nic_group' => 'test-group', 'ip' => '2001:db8::5', 'cloud_properties' => { 'subnet' => 'subnet_id', 'primary_ipv6' => true }})
            nic_group = NicGroup.new('test-group', [other_ipv4, primary6])
            expect(nic_group.primary_ipv6?).to be true
            expect(nic_group.ipv6_address).to eq('2001:db8::5')
          end
        end

        context 'when primary_ipv6: true is set on a ULA (unique local) address' do
          it 'raises an error because a primary IPv6 must be a global unicast address' do
            ula_primary6 = manual_network('ula-primary6', {'nic_group' => 'test-group', 'ip' => 'fd00:db8::1', 'cloud_properties' => { 'subnet' => 'subnet_id', 'primary_ipv6' => true }})
            expect {
              NicGroup.new('test-group', [ula_primary6])
            }.to raise_error(Bosh::Clouds::CloudError, /unique local address \(ULA\)/)
          end

          it 'rejects the fc00 half of the ULA range as well' do
            ula_primary6 = manual_network('ula-primary6', {'nic_group' => 'test-group', 'ip' => 'fc00::1', 'cloud_properties' => { 'subnet' => 'subnet_id', 'primary_ipv6' => true }})
            expect {
              NicGroup.new('test-group', [ula_primary6])
            }.to raise_error(Bosh::Clouds::CloudError, /unique local address \(ULA\)/)
          end
        end

        context 'when a GUA IPv6 address that starts near the ULA range is used with primary_ipv6' do
          it 'is allowed because fe80/link-local and 2000::/3 GUA are not ULA' do
            gua_primary6 = manual_network('gua-primary6', {'nic_group' => 'test-group', 'ip' => '2001:db8::1', 'cloud_properties' => { 'subnet' => 'subnet_id', 'primary_ipv6' => true }})
            nic_group = NicGroup.new('test-group', [gua_primary6])
            expect(nic_group.primary_ipv6?).to be true
            expect(nic_group.ipv6_address).to eq('2001:db8::1')
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