require 'spec_helper'

describe Bosh::AwsCloud::CloudV1 do
  describe '#snapshot_disk' do
    let(:volume) { double(Aws::EC2::Volume, id: 'vol-xxxxxxxx') }
    let(:snapshot) { double(Aws::EC2::Snapshot, id: 'snap-xxxxxxxx') }
    let(:attachment) { double(Aws::EC2::Types::VolumeAttachment, device: '/dev/sdf') }
    let(:metadata) do
      {
        agent_id: 'agent',
        instance_id: 'instance',
        director_name: 'Test Director',
        director_uuid: '6d06b0cc-2c08-43c5-95be-f1b2dd247e18',
        deployment: 'deployment',
        job: 'job',
        index: '0'
      }
    end

    it 'should take a snapshot of a disk' do
      cloud = mock_cloud do |ec2|
        expect(ec2).to receive(:volume).with('vol-xxxxxxxx').and_return(volume)
        expect(volume).to receive(:attachments).and_return([attachment])
        expect(volume).to receive(:create_snapshot) do |args|
          expect(args[:description]).to eq('deployment/job/0/sdf')
          expect(args[:tag_specifications].length).to eq(1)
          expect(args[:tag_specifications][0][:resource_type]).to eq('snapshot')
          expect(args[:tag_specifications][0][:tags]).to include(
            { key: 'agent_id', value: 'agent' },
            { key: 'Name', value: 'deployment/job/0/sdf' }
          )
          snapshot
        end
      end

      expect(Bosh::AwsCloud::ResourceWait).to receive(:for_snapshot).with(snapshot: snapshot, state: 'completed')

      cloud.snapshot_disk('vol-xxxxxxxx', metadata)
    end

    it 'handles string keys in metadata' do
      metadata_str = {
        'agent_id' => 'agent',
        'instance_id' => 'instance',
        'director_name' => 'Test Director',
        'director_uuid' => '6d06b0cc-2c08-43c5-95be-f1b2dd247e18',
        'deployment' => 'deployment',
        'job' => 'job',
        'index' => '0'
      }

      cloud = mock_cloud do |ec2|
        expect(ec2).to receive(:volume).with('vol-xxxxxxxx').and_return(volume)
        allow(volume).to receive(:attachments).and_return([attachment])
        expect(volume).to receive(:create_snapshot) do |args|
          expect(args[:description]).to eq('deployment/job/0/sdf')
          expect(args[:tag_specifications][0][:resource_type]).to eq('snapshot')
          expect(args[:tag_specifications][0][:tags]).to include(
            { key: 'agent_id', value: 'agent' },
            { key: 'Name', value: 'deployment/job/0/sdf' }
          )
          snapshot
        end
      end

      allow(Bosh::AwsCloud::ResourceWait).to receive(:for_snapshot).with(snapshot: snapshot, state: 'completed')

      cloud.snapshot_disk('vol-xxxxxxxx', metadata_str)
    end

    it 'should take a snapshot of a disk not attached to any instance' do
      cloud = mock_cloud do |ec2|
        expect(ec2).to receive(:volume).with('vol-xxxxxxxx').and_return(volume)
        expect(volume).to receive(:attachments).and_return([])
        expect(volume).to receive(:create_snapshot) do |args|
          expect(args[:description]).to eq('deployment/job/0')
          expect(args[:tag_specifications][0][:resource_type]).to eq('snapshot')
          expect(args[:tag_specifications][0][:tags]).to include(
            { key: 'Name', value: 'deployment/job/0' }
          )
          snapshot
        end
      end

      expect(Bosh::AwsCloud::ResourceWait).to receive(:for_snapshot).with(
        snapshot: snapshot, state: 'completed'
      )

      cloud.snapshot_disk('vol-xxxxxxxx', metadata)
    end
  end
end
