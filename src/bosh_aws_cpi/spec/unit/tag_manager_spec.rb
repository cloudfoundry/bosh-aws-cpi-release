require 'spec_helper'

describe Bosh::AwsCloud::TagManager do
  let(:instance) { double('instance', :id => 'i-xxxxxxx') }

  it 'should trim key and value length' do
    expect(instance).to receive(:create_tags) do |args|
      tag = args[:tags].first
      expect(tag[:key].size).to eq(127)
      expect(tag[:value].size).to eq(255)
    end

    Bosh::AwsCloud::TagManager.tag(instance, 'x'*128, 'y'*256)
  end

  it 'casts key and value to strings' do
    expect(instance).to receive(:create_tags).with(tags: [key: 'key', value: 'value'])
    Bosh::AwsCloud::TagManager.tag(instance, :key, :value)

    expect(instance).to receive(:create_tags).with(tags: [key: 'key', value: '8'])
    Bosh::AwsCloud::TagManager.tag(instance, :key, 8)
  end

  it 'should retry tagging when the tagged object is not found' do
    allow(Bosh::AwsCloud::TagManager).to receive(:sleep)
    stub_taggable_to_throw_exception_two_times(instance, Aws::EC2::Errors::InvalidAMIIDNotFound.new(nil, 'not-found'))

    Bosh::AwsCloud::TagManager.tag(instance, 'key', 'value')

    expect(instance).to have_received(:create_tags).exactly(3).times
  end

  context 'when volume' do
    let(:volume) { double("volume", id: 'vol-foo') }
    before(:each) do
      allow(Bosh::AwsCloud::TagManager).to receive(:sleep)
    end

    it 'should retry tagging when volume is not found' do
      allow(Bosh::Clouds::Config.logger).to receive(:warn)
      stub_taggable_to_throw_exception_two_times(volume, Aws::EC2::Errors::InvalidVolumeNotFound.new(nil, 'not-found'))

      Bosh::AwsCloud::TagManager.tags(volume, { 'key1' => 'value1', 'key2' => 'value2' })

      expect(Bosh::Clouds::Config.logger).to have_received(:warn).with("tagged object doesn't exist: vol-foo").twice
      expect(volume).to have_received(:create_tags).exactly(3).times
    end
  end

  it 'should create all tags' do
    expect(instance).to receive(:create_tags).with(
      tags: [{ key: 'key1', value: 'value1'}, {key: 'key2', value: 'value2' }]
    )

    Bosh::AwsCloud::TagManager.tags(instance, { 'key1' => 'value1', 'key2' => 'value2' })
  end

  it 'should create all tags that has non nil keys' do
    expect(instance).to receive(:create_tags).with(
      tags: [{key: 'key2', value: 'value2' }]
    )

    Bosh::AwsCloud::TagManager.tags(instance, { nil => 'value1', 'key2' => 'value2' })
  end

  it 'should create all tags that has non nil values' do
    expect(instance).to receive(:create_tags).with(
      tags: [{key: 'key2', value: 'value2' }]
    )

    Bosh::AwsCloud::TagManager.tags(instance, { 'key1' => nil, 'key2' => 'value2' })
  end

  it 'should do nothing if key is nil' do
    expect(instance).not_to receive(:create_tag)
    Bosh::AwsCloud::TagManager.tag(instance, nil, 'value')
  end

  it 'should do nothing if value is nil' do
    expect(instance).not_to receive(:create_tag)
    Bosh::AwsCloud::TagManager.tag(instance, 'key', nil)
  end

  def stub_taggable_to_throw_exception_two_times(taggable, exception)
    allow(taggable).to receive(:create_tags) do
      @count ||= 0
      if @count < 2
        @count +=1
        raise exception
      end
    end
  end
end
