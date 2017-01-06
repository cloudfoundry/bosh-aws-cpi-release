require 'spec_helper'

describe Bosh::AwsCloud::Cloud, '#set_vm_metadata' do
  let(:instance) { double('instance', :id => 'i-foobar') }

  before :each do
    @cloud = mock_cloud do |ec2|
      allow(ec2).to receive(:instance).with('i-foobar').and_return(instance)
    end
  end

  it 'should add new tags for regular jobs' do
    metadata = {:job => 'fake-job', :index => 'fake-index', :director => 'fake-director'}

    expect(Bosh::AwsCloud::TagManager).to receive(:tag).with(instance, 'job', 'fake-job')
    expect(Bosh::AwsCloud::TagManager).to receive(:tag).with(instance, 'index', 'fake-index')
    expect(Bosh::AwsCloud::TagManager).to receive(:tag).with(instance, 'director', 'fake-director')
    expect(Bosh::AwsCloud::TagManager).to receive(:tag).with(instance, 'Name', 'fake-job/fake-index')

    @cloud.set_vm_metadata('i-foobar', metadata)
  end

  it 'should add new tags for compiling jobs' do
    metadata = {:compiling => 'linux'}

    expect(Bosh::AwsCloud::TagManager).to receive(:tag).with(instance, 'compiling', 'linux')
    expect(Bosh::AwsCloud::TagManager).to receive(:tag).with(instance, 'Name', 'compiling/linux')

    @cloud.set_vm_metadata('i-foobar', metadata)
  end

  it 'handles string keys' do
    metadata = {'job' => 'fake-job', 'index' => 'fake-index'}

    expect(Bosh::AwsCloud::TagManager).to receive(:tag).with(instance, 'job', 'fake-job')
    expect(Bosh::AwsCloud::TagManager).to receive(:tag).with(instance, 'index', 'fake-index')
    expect(Bosh::AwsCloud::TagManager).to receive(:tag).with(instance, 'Name', 'fake-job/fake-index')

    @cloud.set_vm_metadata('i-foobar', metadata)
  end

  context 'when name is provided in metadata' do
    it 'sets the Name tag' do
      metadata = {:name => 'fake-name'}

      expect(Bosh::AwsCloud::TagManager).to receive(:tag).with(instance, 'Name', 'fake-name')
      expect(Bosh::AwsCloud::TagManager).to_not receive(:tag).with(instance, 'name', 'fake-name')

      @cloud.set_vm_metadata('i-foobar', metadata)
    end

    it 'sets the Name tag when also given job and index' do
      metadata = {:name => 'fake-name', :job => 'fake-job', :index => 'fake-index'}

      expect(Bosh::AwsCloud::TagManager).to receive(:tag).with(instance, 'job', 'fake-job')
      expect(Bosh::AwsCloud::TagManager).to receive(:tag).with(instance, 'index', 'fake-index')
      expect(Bosh::AwsCloud::TagManager).to receive(:tag).with(instance, 'Name', 'fake-name')
      expect(Bosh::AwsCloud::TagManager).to_not receive(:tag).with(instance, 'name', 'fake-name')

      @cloud.set_vm_metadata('i-foobar', metadata)
    end

    it 'overrides the Name tag even for compiling jobs' do
      metadata = {:name => 'fake-name', :compiling => 'linux'}

      expect(Bosh::AwsCloud::TagManager).to receive(:tag).with(instance, 'compiling', 'linux')
      expect(Bosh::AwsCloud::TagManager).to receive(:tag).with(instance, 'Name', 'fake-name')

      @cloud.set_vm_metadata('i-foobar', metadata)
    end
  end
end
