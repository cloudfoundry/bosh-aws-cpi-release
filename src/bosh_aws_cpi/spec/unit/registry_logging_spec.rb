require 'spec_helper'
require 'stringio'

describe 'Registry settings updates' do
  it 'retains credentials in registry data while excluding them from logs' do
    settings = {
      'mbus' => 'nats://user:fixture-nats-password@bus:4222',
      'env' => { 'bosh' => { 'private_key' => 'fixture-private-key', 'blobstore_password' => 'fixture-blobstore-password' } },
      'disks' => { 'persistent' => {} }
    }
    registry = instance_double(Bosh::Cpi::RegistryClient)
    allow(registry).to receive(:read_settings).with('instance').and_return(settings)
    expect(registry).to receive(:update_settings).with('instance', settings) do |_, updated|
      expect(updated['mbus']).to include('fixture-nats-password')
      expect(updated['env']).to eq(settings['env'])
      expect(updated['disks']['persistent']).to eq('disk' => '/dev/sdf')
    end
    output = StringIO.new
    cloud = Bosh::AwsCloud::CloudV1.allocate
    cloud.instance_variable_set(:@registry, registry)
    cloud.logger = Logger.new(output)
    cloud.send(:update_agent_settings, 'instance') { |current| current['disks']['persistent']['disk'] = '/dev/sdf' }
    expect(output.string).not_to include('fixture-nats-password', 'fixture-private-key', 'fixture-blobstore-password')
    expect(registry).to have_received(:read_settings).once
  end
end
