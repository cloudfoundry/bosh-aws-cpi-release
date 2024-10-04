# Copyright (c) 2009-2012 VMware, Inc.

require 'spec_helper'

describe Bosh::AwsCloud::CloudV1 do
  let(:volume) { double(Aws::EC2::Volume, id: 'v-foo') }
  let(:cloud) do
    mock_cloud do |ec2|
      allow(ec2).to receive(:volume).with('v-foo').and_return(volume)
    end
  end

  before do
    allow(Bosh::AwsCloud::ResourceWait).to receive_messages(sleep_callback: 0)
  end

  it 'deletes an EC2 volume' do
    allow(Bosh::AwsCloud::ResourceWait).to receive_messages(for_volume: { volume: volume, state: 'deleted' })

    expect(volume).to receive(:delete)

    cloud.delete_disk('v-foo')
  end

  it 'retries deleting the volume if it is in use' do
    allow(Bosh::AwsCloud::ResourceWait).to receive_messages(for_volume: { volume: volume, state: 'deleted' })

    expect(volume).to receive(:delete).once.ordered.and_raise(Aws::EC2::Errors::VolumeInUse.new(nil, 'error-message'))
    expect(volume).to receive(:delete).ordered

    cloud.delete_disk('v-foo')
  end

  it 'raises an error if the volume remains in use after every deletion retry' do
    expect(volume).to receive(:delete)
      .exactly(Bosh::AwsCloud::ResourceWait::DEFAULT_WAIT_ATTEMPTS).times
      .and_raise(Aws::EC2::Errors::VolumeInUse.new(nil, 'error-message'))

    expect do
      cloud.delete_disk('v-foo')
    end.to raise_error("Timed out waiting to delete volume `v-foo'")
  end

  it 'does a fast path delete when asked to' do
    options = mock_cloud_options['properties']
    options['aws']['fast_path_delete'] = 'yes'
    cloud = mock_cloud(options) do |ec2|
      allow(ec2).to receive(:volume).with('v-foo').and_return(volume)
    end

    expect(volume).to receive(:delete)
    expect(volume).to receive(:create_tags).with(tags: [{ key: 'Name', value: 'to be deleted' }])
    expect(Bosh::AwsCloud::ResourceWait).not_to receive(:for_volume)

    cloud.delete_disk('v-foo')
  end

  it 'raises the Clouds::DiskNotFound error when the disk is not found' do
    expect(volume).to receive(:delete).and_raise(Aws::EC2::Errors::InvalidVolumeNotFound.new(nil, 'error-message'))

    expect do
      cloud.delete_disk('v-foo')
    end.to(raise_error { |error|
      expect(error).to be_a(Bosh::Clouds::DiskNotFound)
      expect(error.ok_to_retry).to eq(false)
      expect(error.message).to match(/Disk 'v-foo' not found/)
    })
  end
end
