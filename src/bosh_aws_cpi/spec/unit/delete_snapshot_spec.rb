require 'spec_helper'

describe Bosh::AwsCloud::Cloud do
  describe '#delete_snapshot' do
    let(:snapshot) { double(Aws::EC2::Snapshot, id: 'snap-xxxxxxxx') }

    let(:cloud) {
      mock_cloud do |ec2|
        allow(ec2).to receive(:snapshot).with('snap-xxxxxxxx').and_return(snapshot)
      end
    }

    it 'should delete a snapshot' do
      expect(snapshot).to receive(:delete)

      cloud.delete_snapshot('snap-xxxxxxxx')
    end
  end
end
