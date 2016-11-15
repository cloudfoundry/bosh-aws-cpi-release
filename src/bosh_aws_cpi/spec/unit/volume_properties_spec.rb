require 'spec_helper'

module Bosh::AwsCloud
  describe VolumeProperties do
    let(:minimal_options) { {} }
    let(:maximal_options) do
      {
        size: 2048,
        type: 'io1',
        iops: 1,
        az: 'us-east-1a',
        encrypted: true,
        kms_key_arn: 'my_fake_kms_arn',
        virtualization_type: 'paravirtual',
      }
    end
    describe '#ephemeral_disk_config' do

      context 'given a minimal set of options' do
        subject(:volume_properties) {described_class.new(minimal_options)}
        it 'maps the properties to the disk' do
          vp = volume_properties.ephemeral_disk_config
          expect(vp).to eq({
            device_name: '/dev/sdb',
            ebs: {
              volume_size: 0,
              volume_type: 'gp2',
              delete_on_termination: true
            }
          })
        end
      end

      context 'given a maximal set of options' do
        subject(:volume_properties) {described_class.new(maximal_options)}
        it 'maps the properties to the disk' do
          vp = volume_properties.ephemeral_disk_config
          expect(vp).to eq({
            device_name: '/dev/sdb',
            ebs: {
              volume_size: 2,
              volume_type: 'io1',
              iops: 1,
              encrypted: true,
              delete_on_termination: true,
            }
          })
        end
      end
    end

    describe '#persistent_disk_config' do
      context 'given a minimal set of options' do
        subject(:volume_properties) {described_class.new(minimal_options)}
        it 'returns the correct persistent_disk_config' do
          vp = volume_properties.persistent_disk_config
          expect(vp).to eq({
            size: 0,
            availability_zone: nil,
            volume_type: 'gp2',
            encrypted: false,
          })
        end
      end

      context 'given a maximal set of options' do
        subject(:volume_properties) {described_class.new(maximal_options)}
        it 'returns the correct persistent_disk_config' do
          vp = volume_properties.persistent_disk_config
          expect(vp).to eq({
            size: 2,
            availability_zone: 'us-east-1a',
            volume_type: 'io1',
            encrypted: true,
            iops: 1,
            kms_key_id: 'my_fake_kms_arn'
          })
        end
      end
    end

    describe '#root_disk_config' do
      context 'given a minimal set of options' do
        subject(:volume_properties) {described_class.new(minimal_options)}
        it 'returns the correct root_disk_config' do
          vp = volume_properties.root_disk_config
          expect(vp).to eq({
            device_name: '/dev/xvda',
            ebs: {
              volume_size: 0,
              volume_type: 'gp2',
              delete_on_termination: true,
            }
          })
        end
      end

      context 'given a maximal set of options' do
        subject(:volume_properties) {described_class.new(maximal_options)}
        it 'returns the correct root_disk_config' do
          vp = volume_properties.root_disk_config
          expect(vp).to eq({
            device_name: '/dev/sda',
            ebs: {
              volume_size: 2,
              volume_type: 'io1',
              iops: 1,
              delete_on_termination: true,
            }
          })
        end
      end
    end

    describe '#default_root_disk_to_gp2' do
      context 'given no root_disk section in manifest' do
        subject(:volume_properties) {described_class.new(minimal_options)}
        it 'returns a volume_type of gp2' do
          vp = volume_properties.default_root_disk_volume_type
          expect(vp).to eq({
             device_name: '/dev/xvda',
             ebs: {
                 volume_type: 'gp2',
             }
           })
        end
      end
    end
  end
end
