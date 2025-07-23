require 'spec_helper'
require File.expand_path(File.dirname(__FILE__) + '/../spec_helper')

describe Bosh::AwsCloud::AgentSettings do
  subject {described_class.new(registry, network_props, dns)}

  let(:vm_id) {'1'}
  let(:agent_id) {'agent-id'}
  let(:environment) {nil}
  let(:root_device_name) {'root-device-name'}
  let(:registry) {{'endpoint' => 'some.place'}}
  let(:dns) {{'nameserver' => 'some.ns.com'}}
  let(:agent_disk_info) do
    {
      'ephemeral' => [{'path' => '/dev/sdz'}],
      'raw_ephemeral' => [{'path' => '/dev/xvdba'}, {'path' => '/dev/xvdbb'}]
    }
  end
  let(:agent_config) {{'baz' => 'qux'}}
  let(:networks_spec) do
    {
      'fake-network-name-1' => {
        'type' => 'dynamic'
      },
      'fake-network-name-2' => {
        'type' => 'manual'
      }
    }
  end
  let(:aws_config) do
    instance_double(Bosh::AwsCloud::AwsConfig, stemcell: {}, encrypted: false, kms_key_arn: nil)
  end
  let(:global_config) {instance_double(Bosh::AwsCloud::Config, aws: aws_config)}
  let(:network_props) {Bosh::AwsCloud::NetworkCloudProps.new(networks_spec, global_config)}

  before do
    allow(SecureRandom).to receive(:uuid).and_return(vm_id)
  end

  context '#agent_settings' do
    let(:expected_agent_settings) do
      {
        'vm' => {
          'name' => "vm-#{vm_id}",
        },
        'agent_id' => agent_id,
        'baz' => 'qux',
        'networks' => {
          'fake-network-name-1' => {
            'type' => 'dynamic',
            'use_dhcp' => true
          },
          'fake-network-name-2' => {
            'type' => 'manual',
            'use_dhcp' => true
          }
        },
        'disks' => {
          'system' => root_device_name,
          'persistent' => {},
          'ephemeral' => '/dev/sdz',
          'raw_ephemeral' => [{'path' => '/dev/xvdba'}, {'path' => '/dev/xvdbb'}]
        }
      }
    end

    before do
      subject.agent_disk_info = agent_disk_info
      subject.agent_config = agent_config
      subject.agent_id = agent_id
      subject.root_device_name = root_device_name
    end

    it 'should return a hash with the information specified' do
      expect(subject.agent_settings).to eq(expected_agent_settings)
    end

    context 'when environment is specified' do
      let(:environment) {{'foo' => 'bar'}}

      before do
        subject.environment = environment
        expected_agent_settings['env'] = environment
      end

      it 'should include environment in the settings' do
        expect(subject.agent_settings).to eq(expected_agent_settings)
      end
    end

    context 'when no ephemeral disk is specified' do
      it 'should have empty ephemeral disk info' do
        subject.agent_disk_info = {}

        expect(subject.agent_settings['disks']).to eq({
          'system' => root_device_name,
          'persistent' => {}
        })
      end
    end
  end

  context '#user_data' do
    let(:expected_user_data) do
      {
        'registry' => registry,
        'dns' => dns,
        'networks' => {
          'fake-network-name-1' => {
            'type' => 'dynamic',
            'use_dhcp' => true
          },
          'fake-network-name-2' => {
            'type' => 'manual',
            'use_dhcp' => true
          }
        }
      }
    end

    it 'should return the correct user_data' do
      expect(subject.user_data).to eq(expected_user_data)
    end
  end

  context '#update_agent_networks_settings' do
    let(:mac_address) {'fake-mac-address'}
    let(:networks) do
      {
        'fake-network-name-1' => {
          'type' => 'dynamic',
          'use_dhcp' => true
        },
        'fake-network-name-2' => {
          'type' => 'manual',
          'use_dhcp' => true
        }
      }
    end
    it 'should update the networks with the mac address' do
      subject.update_agent_networks_settings(mac_address)

      expect(subject.networks['fake-network-name-1'][:mac]).to eq(mac_address)
      expect(subject.networks['fake-network-name-2'][:mac]).to eq(mac_address)
    end
  end

  describe 'cpi api version 1' do
    let(:version) {1}

    let(:expected_settings) do
      {
        'registry' => registry,
        'dns' => dns,
        'networks' => {
          'fake-network-name-1' => {
            'type' => 'dynamic',
            'use_dhcp' => true
          },
          'fake-network-name-2' => {
            'type' => 'manual',
            'use_dhcp' => true
          }
        }
      }
    end

    context '#settings_for_version' do
      it 'should return user data' do
        expect(subject.settings_for_version(version)).to eq(expected_settings)
      end
    end

    context '#encode' do
      it 'should encode the settings' do
        encoded = subject.encode(version)
        decoded = JSON.parse(Base64.decode64(encoded))
        expect(decoded).to eq(expected_settings)
      end
    end
  end

  describe 'cpi api version 2' do
    let(:version) {2}
    let(:expected_settings) do
      {
        'registry' => registry,
        'dns' => dns,
        'vm' => {
          'name' => "vm-#{vm_id}",
        },
        'agent_id' => agent_id,
        'networks' => {
          'fake-network-name-1' => {
            'type' => 'dynamic',
            'use_dhcp' => true
          },
          'fake-network-name-2' => {
            'type' => 'manual',
            'use_dhcp' => true
          }
        },
        'baz' => 'qux',
        'disks' => {
          'system' => root_device_name,
          'persistent' => {},
          'ephemeral' => '/dev/sdz',
          'raw_ephemeral' => [{'path' => '/dev/xvdba'}, {'path' => '/dev/xvdbb'}]
        }
      }
    end

    before do
      subject.agent_disk_info = agent_disk_info
      subject.agent_config = agent_config
      subject.agent_id = agent_id
      subject.root_device_name = root_device_name
    end

    context '#settings_for_version' do
      it 'should return user data' do
        expect(subject.settings_for_version(version)).to eq(expected_settings)
      end
    end

    context '#encode' do
      it 'should encode the settings' do
        encoded = subject.encode(version)
        decoded = JSON.parse(Base64.decode64(encoded))
        expect(decoded).to eq(expected_settings)
      end
    end

    context 'when registry is not supplied' do
      let(:registry) { nil }

      before do
        expected_settings.delete('registry')
      end

      it 'does not add registry settings to user data' do
        expect(subject.settings_for_version(version)).to eq(expected_settings)
      end
    end
  end

  describe 'cpi api version invalid' do
    it 'raises an error with a nil version' do
      expect{subject.settings_for_version(nil)}.to raise_error(Bosh::Clouds::CPIAPIVersionNotSupported)
    end
  end
end
