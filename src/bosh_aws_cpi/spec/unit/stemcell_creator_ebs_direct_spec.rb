require 'spec_helper'

# Unit coverage for the EBS-direct heavy-stemcell write path. The cloud-layer
# specs (create_stemcell_ebs_direct_spec.rb / _v3_spec.rb) stub StemcellCreator
# wholesale, so these specs exercise the actual server-side mechanism: the
# StartSnapshot -> PutSnapshotBlock -> CompleteSnapshot sequence, zero-block
# skipping, per-block SHA256 checksums, volume-size rounding, encryption
# params, and cleanup/registration. The Aws::EBS::Client is stubbed -- no real
# AWS.
module Bosh::AwsCloud
  describe StemcellCreator do
    let(:ec2_client) { instance_double(Aws::EC2::Client) }
    let(:ec2_config) { double('ec2_config', region: 'us-east-1', credentials: nil) }
    let(:ec2_resource) { instance_double(Aws::EC2::Resource, client: ec2_client) }
    let(:ebs_client) { instance_double(Aws::EBS::Client) }
    let(:properties) do
      {
        'name' => 'stemcell-name',
        'version' => '0.7.0',
        'infrastructure' => 'aws',
        'architecture' => 'x86_64',
        'root_device_name' => '/dev/xvda',
        'virtualization_type' => 'hvm',
      }
    end
    let(:aws_config) do
      instance_double(Bosh::AwsCloud::AwsConfig, stemcell: {}, encrypted: false, kms_key_arn: nil)
    end
    let(:global_config) { instance_double(Bosh::AwsCloud::Config, aws: aws_config) }
    let(:stemcell_cloud_props) { Bosh::AwsCloud::StemcellCloudProps.new(properties, global_config) }
    let(:creator) { described_class.new(ec2_resource, stemcell_cloud_props) }

    let(:block_size) { 524288 }

    before do
      allow(ec2_client).to receive(:config).and_return(ec2_config)
      allow(Aws::EBS::Client).to receive(:new).and_return(ebs_client)
      allow(SecureRandom).to receive(:uuid).and_return('fake-uuid')
    end

    # Writes a real temp file of the given content so the block reader/skipper
    # runs against actual bytes.
    def with_root_img(bytes)
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'root.img')
        File.binwrite(path, bytes)
        yield path
      end
    end

    def start_response(snapshot_id: 'snap-ebs', bs: 524288)
      double('start', snapshot_id: snapshot_id, block_size: bs)
    end

    describe '#write_snapshot_via_ebs_direct' do
      it 'runs StartSnapshot -> PutSnapshotBlock (non-zero blocks only) -> CompleteSnapshot' do
        # 3 blocks: [data][zeros][data] -> only 2 puts, at indices 0 and 2.
        data_block = ('A'.b * block_size)
        zero_block = ("\0".b * block_size)
        img = data_block + zero_block + ('B'.b * block_size)

        expect(ebs_client).to receive(:start_snapshot) do |params|
          expect(params[:volume_size]).to eq(1) # ~1.5 MiB rounds up to 1 GiB
          expect(params[:timeout]).to eq(60)
          expect(params).not_to have_key(:encrypted)
          start_response
        end

        put_indexes = []
        expect(ebs_client).to receive(:put_snapshot_block).twice do |params|
          put_indexes << params[:block_index]
          expect(params[:data_length]).to eq(block_size)
          expect(params[:checksum_algorithm]).to eq('SHA256')
          # checksum is the base64 SHA256 of the block data
          expected = Base64.strict_encode64(Digest::SHA256.digest(params[:block_data].read))
          expect(params[:checksum]).to eq(expected)
          double('put')
        end

        expect(ebs_client).to receive(:complete_snapshot)
          .with(snapshot_id: 'snap-ebs', changed_blocks_count: 2)

        allow(creator).to receive(:wait_for_snapshot_completed)

        with_root_img(img) do |path|
          expect(creator.send(:write_snapshot_via_ebs_direct, path, false, nil)).to eq('snap-ebs')
        end

        expect(put_indexes.sort).to eq([0, 2])
      end

      it 'rounds the volume size up to whole GiB (>= image size)' do
        # 1 GiB + 1 byte must request a 2 GiB volume.
        img = ("\0".b * block_size) + 'x'.b # tiny, but force size via stub instead

        expect(ebs_client).to receive(:start_snapshot) do |params|
          expect(params[:volume_size]).to eq(2)
          start_response
        end
        allow(ebs_client).to receive(:put_snapshot_block).and_return(double('put'))
        allow(ebs_client).to receive(:complete_snapshot)
        allow(creator).to receive(:wait_for_snapshot_completed)

        with_root_img(img) do |path|
          allow(File).to receive(:size).and_call_original
          allow(File).to receive(:size).with(path).and_return((1024 * 1024 * 1024) + 1)
          creator.send(:write_snapshot_via_ebs_direct, path, false, nil)
        end
      end

      it 'requests encryption with the account default key when encrypted is true and no ARN' do
        expect(ebs_client).to receive(:start_snapshot) do |params|
          expect(params[:encrypted]).to be(true)
          expect(params).not_to have_key(:kms_key_arn)
          start_response
        end
        allow(ebs_client).to receive(:complete_snapshot)
        allow(creator).to receive(:wait_for_snapshot_completed)

        with_root_img("\0".b * block_size) do |path|
          creator.send(:write_snapshot_via_ebs_direct, path, true, nil)
        end
      end

      it 'requests encryption with the supplied KMS key' do
        expect(ebs_client).to receive(:start_snapshot) do |params|
          expect(params[:encrypted]).to be(true)
          expect(params[:kms_key_arn]).to eq('arn:aws:kms:us-east-1:ID:key/GUID')
          start_response
        end
        allow(ebs_client).to receive(:complete_snapshot)
        allow(creator).to receive(:wait_for_snapshot_completed)

        with_root_img("\0".b * block_size) do |path|
          creator.send(:write_snapshot_via_ebs_direct, path, false, 'arn:aws:kms:us-east-1:ID:key/GUID')
        end
      end

      it 'wraps AWS service errors in a CloudError' do
        allow(ebs_client).to receive(:start_snapshot)
          .and_raise(Aws::Errors::ServiceError.new(nil, 'nope'))

        with_root_img('x'.b * 10) do |path|
          expect {
            creator.send(:write_snapshot_via_ebs_direct, path, false, nil)
          }.to raise_error(Bosh::Clouds::CloudError, /EBS direct snapshot creation failed: nope/)
        end
      end
    end

    describe '#create' do
      it 'extracts, writes the snapshot, tags it, and registers the AMI' do
        stemcell = instance_double(Bosh::AwsCloud::Stemcell)
        allow(creator).to receive(:extract_root_image)
        expect(creator).to receive(:write_snapshot_via_ebs_direct).and_return('snap-ebs').ordered
        expect(creator).to receive(:tag_snapshot).with('snap-ebs').ordered
        expect(creator).to receive(:register_image_from_snapshot).with('snap-ebs').ordered.and_return(stemcell)

        expect(creator.create('/path/to/image.tgz')).to eq(stemcell)
      end
    end

    describe '#extract_root_image' do
      it 'raises a CloudError when tar exits non-zero' do
        Dir.mktmpdir do |dir|
          dest = File.join(dir, 'root.img')
          bogus = File.join(dir, 'not-a-tarball.tgz')
          File.write(bogus, 'this is not a gzip tarball')

          expect {
            creator.send(:extract_root_image, bogus, dest)
          }.to raise_error(Bosh::Clouds::CloudError, /Unable to extract stemcell root image/)
        end
      end
    end

    describe '#tag_snapshot' do
      let(:snapshot) { instance_double(Aws::EC2::Snapshot) }

      it 'does not discard a completed snapshot when tagging hits a transient error' do
        creator.instance_variable_set(:@creation_tags, { 'foo' => 'bar' })
        allow(ec2_resource).to receive(:snapshot).with('snap-ebs').and_return(snapshot)
        allow(Bosh::AwsCloud::TagManager).to receive(:create_tags)
          .and_raise(Aws::Errors::ServiceError.new(nil, 'throttled'))

        expect {
          creator.send(:tag_snapshot, 'snap-ebs')
        }.not_to raise_error
      end
    end
  end
end
