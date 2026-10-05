require 'spec_helper'

module Bosh::AwsCloud
  describe EbsDirectUploader do
    let(:ebs_client)   { instance_double(Aws::EBS::Client) }
    let(:ec2_client)   { instance_double(Aws::EC2::Client) }
    let(:ec2_resource) { instance_double(Aws::EC2::Resource, client: ec2_client) }
    let(:aws_config) do
      instance_double(Bosh::AwsCloud::AwsConfig,
        credentials: nil, max_retries: 3, dualstack: false, region: 'us-east-1')
    end
    let(:uploader) { described_class.new(aws_config, ec2_resource) }
    let(:block_size) { 524288 }

    before do
      allow(Aws::EBS::Client).to receive(:new).and_return(ebs_client)
      allow(SecureRandom).to receive(:uuid).and_return('fake-uuid')
    end

    def with_image(bytes)
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'root.img')
        File.binwrite(path, bytes)
        yield path
      end
    end

    def start_response(snapshot_id: 'snap-001', bs: 524288)
      double('start', snapshot_id: snapshot_id, block_size: bs)
    end

    describe '#upload' do
      it 'runs StartSnapshot -> PutSnapshotBlock for non-zero blocks only -> CompleteSnapshot' do
        data_block = 'A'.b * block_size
        zero_block = "\0".b * block_size
        img = data_block + zero_block + ('B'.b * block_size)

        expect(ebs_client).to receive(:start_snapshot) do |params|
          expect(params[:volume_size]).to eq(2)
          expect(params[:timeout]).to eq(60)
          expect(params).not_to have_key(:encrypted)
          start_response
        end

        put_indexes = []
        expect(ebs_client).to receive(:put_snapshot_block).twice do |params|
          put_indexes << params[:block_index]
          expect(params[:data_length]).to eq(block_size)
          expect(params[:checksum_algorithm]).to eq('SHA256')
          expected_checksum = Base64.strict_encode64(Digest::SHA256.digest(params[:block_data].read))
          expect(params[:checksum]).to eq(expected_checksum)
          double('put')
        end

        expect(ebs_client).to receive(:complete_snapshot)
          .with(snapshot_id: 'snap-001', changed_blocks_count: 2)

        snapshot = instance_double(Aws::EC2::Snapshot)
        allow(ec2_resource).to receive(:snapshot).with('snap-001').and_return(snapshot)
        allow(ResourceWait).to receive(:for_snapshot)

        with_image(img) do |path|
          allow(File).to receive(:size).and_call_original
          allow(File).to receive(:size).with(path).and_return(2 * 1024 * 1024 * 1024)
          result = uploader.upload(path, volume_size_gib: 2)
          expect(result).to eq('snap-001')
        end

        expect(put_indexes.sort).to eq([0, 2])
      end

      it 'requests encryption with the account default key when encrypted: true and no ARN' do
        expect(ebs_client).to receive(:start_snapshot) do |params|
          expect(params[:encrypted]).to be(true)
          expect(params).not_to have_key(:kms_key_arn)
          start_response
        end
        allow(ebs_client).to receive(:put_snapshot_block).and_return(double('put'))
        allow(ebs_client).to receive(:complete_snapshot)
        allow(uploader).to receive(:wait_for_snapshot_completed)

        with_image('x'.b * block_size) do |path|
          uploader.upload(path, volume_size_gib: 1, encrypted: true)
        end
      end

      it 'forwards the KMS key ARN when encrypted: true and an ARN is supplied' do
        expect(ebs_client).to receive(:start_snapshot) do |params|
          expect(params[:encrypted]).to be(true)
          expect(params[:kms_key_arn]).to eq('arn:aws:kms:us-east-1:ID:key/GUID')
          start_response
        end
        allow(ebs_client).to receive(:put_snapshot_block).and_return(double('put'))
        allow(ebs_client).to receive(:complete_snapshot)
        allow(uploader).to receive(:wait_for_snapshot_completed)

        with_image('x'.b * block_size) do |path|
          uploader.upload(path, volume_size_gib: 1, encrypted: true, kms_key_arn: 'arn:aws:kms:us-east-1:ID:key/GUID')
        end
      end

      it 'does not encrypt when encrypted: false even if a KMS ARN is supplied' do
        expect(ebs_client).to receive(:start_snapshot) do |params|
          expect(params).not_to have_key(:encrypted)
          expect(params).not_to have_key(:kms_key_arn)
          start_response
        end
        allow(ebs_client).to receive(:complete_snapshot)
        allow(uploader).to receive(:wait_for_snapshot_completed)

        with_image("\0".b * block_size) do |path|
          uploader.upload(path, volume_size_gib: 1, encrypted: false, kms_key_arn: 'arn:aws:kms:us-east-1:ID:key/GUID')
        end
      end

      it 'zero-pads a short final block to block_size before uploading' do
        short_chunk = 'X'.b * 10
        expect(ebs_client).to receive(:start_snapshot).and_return(start_response)
        expect(ebs_client).to receive(:put_snapshot_block) do |params|
          expect(params[:data_length]).to eq(block_size)
          expect(params[:block_data].read.bytesize).to eq(block_size)
          double('put')
        end
        expect(ebs_client).to receive(:complete_snapshot)
        allow(uploader).to receive(:wait_for_snapshot_completed)

        with_image(short_chunk) do |path|
          uploader.upload(path, volume_size_gib: 1)
        end
      end

      it 'propagates a mid-upload block failure as a CloudError' do
        expect(ebs_client).to receive(:start_snapshot).and_return(start_response)
        allow(ebs_client).to receive(:put_snapshot_block)
          .and_raise(Aws::Errors::ServiceError.new(nil, 'throttled'))

        with_image('X'.b * block_size) do |path|
          expect {
            uploader.upload(path, volume_size_gib: 1)
          }.to raise_error(Bosh::Clouds::CloudError, /EBS direct snapshot creation failed/)
        end
      end

      it 'retries a failing block up to 3 times before giving up' do
        call_count = 0
        expect(ebs_client).to receive(:start_snapshot).and_return(start_response)
        allow(ebs_client).to receive(:put_snapshot_block) do
          call_count += 1
          raise Aws::Errors::ServiceError.new(nil, 'flaky') if call_count <= 3
          double('put')
        end
        expect(ebs_client).to receive(:complete_snapshot)
        allow(uploader).to receive(:wait_for_snapshot_completed)
        allow(uploader).to receive(:sleep)

        with_image('X'.b * block_size) do |path|
          uploader.upload(path, volume_size_gib: 1)
        end

        expect(call_count).to eq(4)
      end

      it 'raises a CloudError when StartSnapshot fails' do
        allow(ebs_client).to receive(:start_snapshot)
          .and_raise(Aws::Errors::ServiceError.new(nil, 'nope'))

        with_image('x'.b * 10) do |path|
          expect {
            uploader.upload(path, volume_size_gib: 1)
          }.to raise_error(Bosh::Clouds::CloudError, /EBS direct snapshot creation failed: nope/)
        end
      end

      it 'raises a CloudError when the snapshot times out waiting for completion' do
        expect(ebs_client).to receive(:start_snapshot).and_return(start_response)
        allow(ebs_client).to receive(:complete_snapshot)

        snapshot = instance_double(Aws::EC2::Snapshot)
        allow(ec2_resource).to receive(:snapshot).with('snap-001').and_return(snapshot)
        allow(ResourceWait).to receive(:for_snapshot)
          .and_raise(Bosh::Common::RetryCountExceeded)

        with_image("\0".b * block_size) do |path|
          expect {
            uploader.upload(path, volume_size_gib: 1)
          }.to raise_error(Bosh::Clouds::CloudError, /Timed out waiting for EBS direct snapshot/)
        end
      end
    end
  end
end
