require 'spec_helper'

describe Bosh::AwsCloud::NetworkInterface do
  let(:aws_network_interface) { double('Aws::EC2::NetworkInterface', id: 'eni-12345', mac_address: '00:11:22:33:44:55') }
  let(:ec2_client) { double('Aws::EC2::Client') }
  let(:logger) { double('Logger', info: nil, warn: nil) }
  let(:network_interface) { described_class.new(aws_network_interface, ec2_client, logger) }

  describe '#id' do
    it 'returns the network interface ID' do
      expect(network_interface.id).to eq('eni-12345')
    end
  end

  describe '#wait_until_available' do
    context 'when the network interface becomes available' do
      it 'logs the waiting process' do
        allow(ec2_client).to receive(:wait_until).with(:network_interface_available, network_interface_ids: ['eni-12345'])
        network_interface.wait_until_available
        expect(logger).to have_received(:info).with('Waiting for network interface to become available...')
      end
    end

    context 'when waiting times out' do
      it 'raises a NetworkInterfaceCreationFailed error' do
        allow(ec2_client).to receive(:wait_until).and_raise(Aws::Waiters::Errors::TooManyAttemptsError.new(1))
        expect {
          network_interface.wait_until_available
        }.to raise_error(Bosh::Clouds::CloudError, /Timed out waiting for network interface/)
        expect(logger).to have_received(:warn).with(/Timed out waiting for network interface/)
      end
    end
  end

  describe '#attach_ip_prefixes' do
    let(:private_ip_addresses) do
      [
        { ip: '192.168.1.1', prefix: 28 },
        { ip: '2001:db8::1', prefix: 80 }
      ]
    end

    it 'attaches IPv4 and IPv6 prefixes to the network interface' do
      allow(ec2_client).to receive(:assign_private_ip_addresses)
      allow(ec2_client).to receive(:assign_ipv_6_addresses)

      network_interface.attach_ip_prefixes(private_ip_addresses)

      expect(ec2_client).to have_received(:assign_private_ip_addresses).with(
        network_interface_id: 'eni-12345',
        ipv_4_prefixes: ['192.168.1.1/28']
      )
      expect(ec2_client).to have_received(:assign_ipv_6_addresses).with(
        network_interface_id: 'eni-12345',
        ipv_6_prefixes: ['2001:db8::1/80']
      )
    end
  end

  describe '#ipv6_address?' do
    it 'returns true for an IPv6 address' do
      expect(network_interface.ipv6_address?('2001:db8::1')).to be true
    end

    it 'returns false for an IPv4 address' do
      expect(network_interface.ipv6_address?('192.168.1.1')).to be false
    end
  end

  describe '#delete' do
    it 'deletes the network interface' do
      allow(aws_network_interface).to receive(:delete)
      network_interface.delete
      expect(aws_network_interface).to have_received(:delete)
    end
  end

  describe '#mac_address' do
    it 'returns the MAC address of the network interface' do
      expect(network_interface.mac_address).to eq('00:11:22:33:44:55')
    end
  end

  describe '#nic_configuration' do
    it 'returns the NIC configuration hash' do
      expect(network_interface.nic_configuration).to eq(
        device_index: 0,
        network_interface_id: 'eni-12345'
      )
    end
  end
end
