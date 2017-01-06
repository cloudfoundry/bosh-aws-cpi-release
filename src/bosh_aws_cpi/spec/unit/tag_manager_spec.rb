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

    expect(instance).to receive(:create_tags).exactly(3).times do
      @count ||= 0
      if @count < 2
        @count += 1
        raise Aws::EC2::Errors::InvalidAMIIDNotFound.new(nil, 'not-found')
      end
    end

    Bosh::AwsCloud::TagManager.tag(instance, 'key', 'value')
  end

  it 'should do nothing if key is nil' do
    expect(instance).not_to receive(:create_tag)
    Bosh::AwsCloud::TagManager.tag(instance, nil, 'value')
  end

  it 'should do nothing if value is nil' do
    expect(instance).not_to receive(:create_tag)
    Bosh::AwsCloud::TagManager.tag(instance, 'key', nil)
  end
end
