require 'spec_helper'

module Bosh::AwsCloud
  describe VolumeProperties do
    let(:minimal_options) { {} }
    let(:maximal_options) { {size: 2048, type: 'my-fake-disk-type', iops: 1, az: 'us-east-1a', encrypted: true} }
    describe '#disk_mapping' do

      context 'given a minimal set of options' do
        subject(:volume_properties) {described_class.new(minimal_options)}
        it 'maps the properties to the disk' do
          vp = volume_properties.disk_mapping
          expect(vp).to eq({
            device_name: '/dev/sdb',
            ebs: {
              volume_size: 0,
              volume_type: 'standard',
              delete_on_termination: true
            }
          })
        end
      end

      context 'given a maximal set of options' do
        subject(:volume_properties) {described_class.new(maximal_options)}
        it 'maps the properties to the disk' do
          vp = volume_properties.disk_mapping
          expect(vp).to eq({
            device_name: '/dev/sdb',
            ebs: {
              volume_size: 2,
              volume_type: 'my-fake-disk-type',
              iops: 1,
              encrypted: true,
              delete_on_termination: true
            }
          })
        end
      end
    end

    describe '#volume_options' do
      context 'given a minimal set of options' do
        subject(:volume_properties) {described_class.new(minimal_options)}
        it 'returns the correct volume_options' do
          vp = volume_properties.volume_options
          expect(vp).to eq({
            size: 0,
            availability_zone: nil,
            volume_type: 'standard',
            encrypted: false,
          })
        end
      end

      context 'given a maximal set of options' do
        subject(:volume_properties) {described_class.new(maximal_options)}
        it 'returns the correct volume_options' do
          vp = volume_properties.volume_options
          expect(vp).to eq({
            size: 2,
            availability_zone: 'us-east-1a',
            volume_type: 'my-fake-disk-type',
            encrypted: true,
            iops: 1,
          })
        end
      end
    end
  end
end
