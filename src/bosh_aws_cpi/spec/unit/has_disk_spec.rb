require 'spec_helper'

describe Bosh::AwsCloud::Cloud do
  describe 'has_disk?' do
    context 'when disk is found' do
      let(:disk) {instance_double('Aws::EC2::Volume', id: 'v-foo', exists?: true, state: 'available')}

      it 'returns true' do
        cloud = mock_cloud do |ec2|
          allow(ec2).to receive(:volume).with("v-foo").and_return(disk)
        end

        expect(cloud.has_disk?('v-foo')).to be(true)
      end
    end

    context 'when disk is not found' do
      let(:disk) {instance_double('Aws::EC2::Volume', id: 'non-existing-disk-uuid') }

      it 'returns false' do
        cloud = mock_cloud do |ec2|
          allow(ec2).to receive(:volume).with('non-existing-disk-uuid').and_return(disk)
        end

        allow(disk).to receive(:state).and_raise(Aws::EC2::Errors::InvalidVolumeNotFound.new(nil, 'not-found'))

        expect(cloud.has_disk?('non-existing-disk-uuid')).to be(false)
      end
    end
  end
end
