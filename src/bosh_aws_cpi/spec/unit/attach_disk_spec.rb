require 'spec_helper'

describe Bosh::AwsCloud::Cloud do

  before(:each) do
    @registry = mock_registry
  end

  let(:instance) { double('instance', :id => 'i-test') }
  let(:volume) { double('volume', :id => 'v-foobar') }
  let(:subnet) { instance_double(Aws::EC2::Subnet) }

  let(:cloud) do
    mock_cloud do |ec2|
      allow(ec2).to receive(:instance).with('i-test').and_return(instance)
      allow(ec2).to receive(:volume).with('v-foobar').and_return(volume)
      allow(ec2).to receive(:subnets).and_return([subnet])
    end
  end

  before { allow(instance).to receive(:block_device_mappings).and_return({}) }

  it 'attaches EC2 volume to an instance' do
    attachment = instance_double(Bosh::AwsCloud::SdkHelpers::VolumeAttachment, device: '/dev/sdf')

    fake_resp = double('attachment-resp')
    expect(volume).to receive(:attach_to_instance).
      with(instance_id: "i-test", device: "/dev/sdf").and_return(fake_resp)

    allow(Bosh::AwsCloud::SdkHelpers::VolumeAttachment).to receive(:new).with(fake_resp, cloud.ec2_resource).and_return(attachment)
    allow(Bosh::AwsCloud::ResourceWait).to receive(:for_attachment).with(attachment: attachment, state: 'attached')

    old_settings = { 'foo' => 'bar'}
    new_settings = {
      'foo' => 'bar',
      'disks' => {
        'persistent' => {
          'v-foobar' => '/dev/sdf'
        }
      }
    }

    expect(@registry).to receive(:read_settings).
      twice.
      with('i-test').
      and_return(old_settings)

    expect(@registry).to receive(:update_settings).with('i-test', new_settings)

    cloud.attach_disk('i-test', 'v-foobar')
  end

  it 'picks next available device name' do
    expect(instance).to receive(:block_device_mappings).
      and_return([
        double(Aws::EC2::Types::InstanceBlockDeviceMapping, device_name: '/dev/sdf'),
        double(Aws::EC2::Types::InstanceBlockDeviceMapping, device_name: '/dev/sdg')
      ])

    fake_resp = double('attachment-resp')
    expect(volume).to receive(:attach_to_instance).
      with(instance_id: "i-test", device: "/dev/sdh").and_return(fake_resp)

    attachment = instance_double(Bosh::AwsCloud::SdkHelpers::VolumeAttachment, device: '/dev/sdh')

    allow(Bosh::AwsCloud::SdkHelpers::VolumeAttachment).to receive(:new).with(fake_resp, cloud.ec2_resource).and_return(attachment)
    allow(Bosh::AwsCloud::ResourceWait).to receive(:for_attachment).with(attachment: attachment, state: 'attached')

    old_settings = { 'foo' => 'bar'}
    new_settings = {
      'foo' => 'bar',
      'disks' => {
        'persistent' => {
          'v-foobar' => '/dev/sdh'
        }
      }
    }

    expect(@registry).to receive(:read_settings).
      twice.
      with('i-test').
      and_return(old_settings)

    expect(@registry).to receive(:update_settings).with('i-test', new_settings)

    cloud.attach_disk('i-test', 'v-foobar')
  end

  it 'raises an error when sdf..sdp are all reserved' do
    all_mappings = ('f'..'p').map do |char|
      double(Aws::EC2::Types::InstanceBlockDeviceMapping, device_name: "/dev/sd#{char}")
    end

    expect(instance).to receive(:block_device_mappings).
      and_return(all_mappings)

    expect {
      cloud.attach_disk('i-test', 'v-foobar')
    }.to raise_error(Bosh::Clouds::CloudError, /too many disks attached/)
  end

  context 'when aws returns IncorrectState' do
    before { allow(Kernel).to receive(:sleep) }

    before do
      allow(volume).to receive(:attach_to_instance).
        with(instance_id: "i-test", device: "/dev/sdf").and_raise(Aws::EC2::Errors::IncorrectState.new(nil, 'fake-message'))
    end

    it 'retries 15 times every 1 sec' do
      expect(volume).to receive(:attach_to_instance).exactly(15).times
      expect {
        cloud.attach_disk('i-test', 'v-foobar')
      }.to raise_error Bosh::Clouds::CloudError, /fake-message/
    end
  end

  context 'when aws returns VolumeInUse' do
    before { allow(Kernel).to receive(:sleep) }

    before do
      allow(volume).to receive(:attach_to_instance).
        with(instance_id: "i-test", device: "/dev/sdf").and_raise Aws::EC2::Errors::VolumeInUse.new(nil, 'fake-message')
    end

    it 'retries default number of attempts' do
      expect(volume).to receive(:attach_to_instance).exactly(
          Bosh::AwsCloud::ResourceWait::DEFAULT_WAIT_ATTEMPTS).times

      expect {
        cloud.attach_disk('i-test', 'v-foobar')
      }.to raise_error Aws::EC2::Errors::VolumeInUse
    end
  end
end
