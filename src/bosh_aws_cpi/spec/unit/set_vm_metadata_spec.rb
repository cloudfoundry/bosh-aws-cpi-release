# frozen_string_literal: true

require 'spec_helper'

describe Bosh::AwsCloud::CloudV1, '#set_vm_metadata' do
  let(:block_device_mappings) do
    [
      OpenStruct.new(ebs: OpenStruct.new(volume_id: 'root-disk')),
      OpenStruct.new(ebs: OpenStruct.new(volume_id: 'ephemeral-disk'))
    ]
  end
  let(:instance) { instance_double(Aws::EC2::Instance, id: 'i-foobar', block_device_mappings: block_device_mappings) }
  let(:root_disk) { instance_double(Aws::EC2::Volume, id: 'vol-root') }
  let(:ephemeral_disk) { instance_double(Aws::EC2::Volume, id: 'vol-ephemeral') }

  before :each do
    @cloud = mock_cloud do |ec2|
      allow(ec2).to receive(:instance).with('i-foobar').and_return(instance)
      allow(ec2).to receive(:volume).with('root-disk').and_return(root_disk)
      allow(ec2).to receive(:volume).with('ephemeral-disk').and_return(ephemeral_disk)
    end
  end

  it 'should add new tags for regular jobs' do
    metadata = { job: 'fake-job', index: 'fake-index', director: 'fake-director' }

    expected_tags = { 'job' => 'fake-job', 'index' => 'fake-index', 'director' => 'fake-director', 'Name' => 'fake-job/fake-index' }
    expect(Bosh::AwsCloud::TagManager).to receive(:tags).with(instance, expected_tags)
    expect(Bosh::AwsCloud::TagManager).to receive(:tags).with(root_disk, expected_tags)
    expect(Bosh::AwsCloud::TagManager).to receive(:tags).with(ephemeral_disk, expected_tags)

    @cloud.set_vm_metadata('i-foobar', metadata)
  end

  it 'should add new tags for compiling jobs' do
    metadata = { compiling: 'linux' }

    expected_tags = { 'compiling' => 'linux', 'Name' => 'compiling/linux' }
    expect(Bosh::AwsCloud::TagManager).to receive(:tags).with(instance, expected_tags)
    expect(Bosh::AwsCloud::TagManager).to receive(:tags).with(root_disk, expected_tags)
    expect(Bosh::AwsCloud::TagManager).to receive(:tags).with(ephemeral_disk, expected_tags)

    @cloud.set_vm_metadata('i-foobar', metadata)
  end

  it 'handles string keys' do
    metadata = { 'job' => 'fake-job', 'index' => 'fake-index' }

    expected_tags = { 'job' => 'fake-job', 'index' => 'fake-index', 'Name' => 'fake-job/fake-index' }
    expect(Bosh::AwsCloud::TagManager).to receive(:tags).with(instance, expected_tags)
    expect(Bosh::AwsCloud::TagManager).to receive(:tags).with(root_disk, expected_tags)
    expect(Bosh::AwsCloud::TagManager).to receive(:tags).with(ephemeral_disk, expected_tags)

    @cloud.set_vm_metadata('i-foobar', metadata)
  end

  context 'when name is provided in metadata' do
    it 'sets the Name tag' do
      metadata = { name: 'fake-name' }

      expected_tags = { 'Name' => 'fake-name' }
      expect(Bosh::AwsCloud::TagManager).to receive(:tags).with(instance, expected_tags)
      expect(Bosh::AwsCloud::TagManager).to receive(:tags).with(root_disk, expected_tags)
      expect(Bosh::AwsCloud::TagManager).to receive(:tags).with(ephemeral_disk, expected_tags)

      @cloud.set_vm_metadata('i-foobar', metadata)
    end

    it 'sets the Name tag when also given job and index' do
      metadata = { name: 'fake-name', job: 'fake-job', index: 'fake-index' }

      expected_tags = { 'job' => 'fake-job', 'index' => 'fake-index', 'Name' => 'fake-name' }
      expect(Bosh::AwsCloud::TagManager).to receive(:tags).with(instance, expected_tags)
      expect(Bosh::AwsCloud::TagManager).to receive(:tags).with(root_disk, expected_tags)
      expect(Bosh::AwsCloud::TagManager).to receive(:tags).with(ephemeral_disk, expected_tags)

      @cloud.set_vm_metadata('i-foobar', metadata)
    end

    it 'overrides the Name tag even for compiling jobs' do
      metadata = { name: 'fake-name', compiling: 'linux' }

      expected_tags = { 'compiling' => 'linux', 'Name' => 'fake-name' }
      expect(Bosh::AwsCloud::TagManager).to receive(:tags).with(instance, expected_tags)
      expect(Bosh::AwsCloud::TagManager).to receive(:tags).with(root_disk, expected_tags)
      expect(Bosh::AwsCloud::TagManager).to receive(:tags).with(ephemeral_disk, expected_tags)

      @cloud.set_vm_metadata('i-foobar', metadata)
    end
  end
end
