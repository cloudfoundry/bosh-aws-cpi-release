#frozen_string_literal: true

require 'spec_helper'

describe Bosh::AwsCloud::TagManager do
  let(:instance) { instance_double(Aws::EC2::Instance, id: 'i-xxxxxxx') }

  it 'should trim key and value length' do
    expect(instance).to receive(:create_tags) do |args|
      tag = args[:tags].first
      expect(tag[:key].size).to eq(127)
      expect(tag[:value].size).to eq(255)
    end

    Bosh::AwsCloud::TagManager.tag(instance, 'x' * 128, 'y' * 256)
  end

  it 'casts key and value to strings' do
    expect(instance).to receive(:create_tags).with(tags: [key: 'key', value: 'value'])
    Bosh::AwsCloud::TagManager.tag(instance, :key, :value)

    expect(instance).to receive(:create_tags).with(tags: [key: 'key', value: '8'])
    Bosh::AwsCloud::TagManager.tag(instance, :key, 8)
  end

  context 'taggable not found' do
    before(:each) do
      allow(Bosh::AwsCloud::TagManager).to receive(:sleep)
      allow(Bosh::Clouds::Config.logger).to receive(:warn)
    end

    context 'when instance' do
      it 'should retry tagging' do
        expect(instance).to receive(:create_tags)
          .and_raise(Aws::EC2::Errors::InvalidAMIIDNotFound.new(nil, 'not-found'))
        expect(instance).to receive(:create_tags)
          .and_return({})

        expect(Bosh::Clouds::Config.logger).to receive(:info).with('attempting to tag object: i-xxxxxxx').twice

        Bosh::AwsCloud::TagManager.tag(instance, 'key', 'value')
      end
    end

    context 'when volume' do
      let(:volume) { double('volume', id: 'vol-foo') }

      it 'should retry tagging' do
        expect(volume).to receive(:create_tags)
          .and_raise(Aws::EC2::Errors::InvalidVolumeNotFound.new(nil, 'not-found'))
        expect(volume).to receive(:create_tags)
          .and_return({})

        expect(Bosh::Clouds::Config.logger).to receive(:info).with('attempting to tag object: vol-foo').twice

        Bosh::AwsCloud::TagManager.create_tags(volume, 'key1' => 'value1', 'key2' => 'value2')
      end
    end
  end

  it 'should create all tags' do
    expect(instance).to receive(:create_tags).with(
      tags: [{ key: 'key1', value: 'value1' }, { key: 'key2', value: 'value2' }]
    )

    Bosh::AwsCloud::TagManager.create_tags(instance, 'key1' => 'value1', 'key2' => 'value2')
  end

  it 'should create all tags that has non nil keys' do
    expect(instance).to receive(:create_tags).with(
      tags: [{ key: 'key2', value: 'value2' }]
    )

    Bosh::AwsCloud::TagManager.create_tags(instance, nil => 'value1', 'key2' => 'value2')
  end

  it 'should create all tags that has non nil values' do
    expect(instance).to receive(:create_tags).with(
      tags: [{ key: 'key2', value: 'value2' }]
    )

    Bosh::AwsCloud::TagManager.create_tags(instance, 'key1' => nil, 'key2' => 'value2')
  end

  it 'should do nothing if key is nil' do
    expect(instance).not_to receive(:create_tags)
    Bosh::AwsCloud::TagManager.tag(instance, nil, 'value')
  end

  it 'should do nothing if value is nil' do
    expect(instance).not_to receive(:create_tags)
    Bosh::AwsCloud::TagManager.tag(instance, 'key', nil)
  end

  describe '.tags_hash' do
    it 'returns nil for non-Hash values' do
      expect(described_class.tags_hash(nil)).to be_nil
      expect(described_class.tags_hash([])).to be_nil
      expect(described_class.tags_hash('tags')).to be_nil
    end

    it 'return custom default when specified' do
      expect(described_class.tags_hash(nil, default: {})).to eq({})
      expect(described_class.tags_hash([], default: {})).to eq({})
    end

    it 'returns a dup of a Hash so mutating the result does not change the original' do
      original = { 'a' => '1' }
      coerced = described_class.tags_hash(original)
      expect(coerced).to eq(original)
      expect(coerced).not_to equal(original)
      coerced['b'] = '2'
      expect(original).to eq('a' => '1')
    end

    it 'returns a dup for an empty Hash' do
      empty = {}
      coerced = described_class.tags_hash(empty)
      expect(coerced).to eq({})
      expect(coerced).not_to equal(empty)
    end
  end

  describe '.tag_specifications_for_resources' do
    it 'returns empty array for nil or empty tags' do
      expect(described_class.tag_specifications_for_resources(nil, ['instance'])).to eq([])
      expect(described_class.tag_specifications_for_resources({}, ['instance'])).to eq([])
    end

    it 'builds one entry per resource type with formatted tags' do
      tags = { 'k' => 'v', 'empty' => nil }
      specs = described_class.tag_specifications_for_resources(tags, %w[instance volume])
      expect(specs.length).to eq(2)
      expect(specs[0][:resource_type]).to eq('instance')
      expect(specs[0][:tags]).to eq([{ key: 'k', value: 'v' }])
      expect(specs[1][:resource_type]).to eq('volume')
      expect(specs[1][:tags]).to eq([{ key: 'k', value: 'v' }])
    end

    it 'accepts a single resource type string' do
      specs = described_class.tag_specifications_for_resources({ 'a' => 'b' }, 'snapshot')
      expect(specs.length).to eq(1)
      expect(specs[0][:resource_type]).to eq('snapshot')
    end
  end
end
