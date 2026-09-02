require 'spec_helper'

# Unit coverage for the StemcellCreator ImportSnapshot mechanism itself.
#
# The cloud-layer specs (create_stemcell_import_snapshot_spec.rb /
# _v3_spec.rb) stub StemcellCreator wholesale, so they only assert routing.
# These specs exercise the actual server-side logic that the ImportSnapshot
# feature exists to add: the poll state machine, the begin/ensure S3 cleanup,
# the encrypted/KMS param construction, and the tar-extraction failure path.
module Bosh::AwsCloud
  describe StemcellCreator do
    let(:ec2_client) { instance_double(Aws::EC2::Client) }
    let(:ec2_resource) { instance_double(Aws::EC2::Resource, client: ec2_client) }
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

    before do
      # Keep the poll loop instant; the real interval would make the suite sleep.
      stub_const('Bosh::AwsCloud::StemcellCreator::IMPORT_SNAPSHOT_POLL_INTERVAL', 0)
      allow(creator).to receive(:sleep)
    end

    describe '#wait_for_import_snapshot' do
      def task_double(status:, snapshot_id: nil, status_message: nil, progress: nil)
        detail = double('detail', status: status, snapshot_id: snapshot_id,
                                   status_message: status_message, progress: progress)
        double('response', import_snapshot_tasks: [double('task', snapshot_task_detail: detail)])
      end

      it 'returns the snapshot id once the task completes, polling past in-progress states' do
        expect(ec2_client).to receive(:describe_import_snapshot_tasks)
          .with(import_task_ids: ['import-task-1'])
          .and_return(
            task_double(status: 'active', progress: '42'),
            task_double(status: 'completed', snapshot_id: 'snap-imported'),
          )

        expect(creator.send(:wait_for_import_snapshot, 'import-task-1')).to eq('snap-imported')
      end

      it 'raises a CloudError when the task ends in a failed state' do
        allow(ec2_client).to receive(:describe_import_snapshot_tasks)
          .and_return(task_double(status: 'error', status_message: 'boom'))

        expect {
          creator.send(:wait_for_import_snapshot, 'import-task-1')
        }.to raise_error(Bosh::Clouds::CloudError, /failed: boom/)
      end

      it 'retries transient describe errors and still completes' do
        call = 0
        allow(ec2_client).to receive(:describe_import_snapshot_tasks) do
          call += 1
          raise Aws::Errors::ServiceError.new(nil, 'throttled') if call == 1

          task_double(status: 'completed', snapshot_id: 'snap-after-retry')
        end

        expect(creator.send(:wait_for_import_snapshot, 'import-task-1')).to eq('snap-after-retry')
      end

      it 'raises ImportSnapshotTimeout if the task never completes within the poll timeout' do
        stub_const('Bosh::AwsCloud::StemcellCreator::IMPORT_SNAPSHOT_POLL_TIMEOUT', -1)
        allow(ec2_client).to receive(:describe_import_snapshot_tasks)
          .and_return(task_double(status: 'active', progress: '10'))

        expect {
          creator.send(:wait_for_import_snapshot, 'import-task-1')
        }.to raise_error(Bosh::AwsCloud::StemcellCreator::ImportSnapshotTimeout, /Timed out after .* waiting for ImportSnapshot task/)
      end

      it 'honors an explicit timeout argument over the default constant' do
        # default constant is large; an explicit already-expired timeout must
        # win so the caller-provided `import_snapshot.timeout` takes effect.
        allow(ec2_client).to receive(:describe_import_snapshot_tasks)
          .and_return(task_double(status: 'active', progress: '10'))

        expect {
          creator.send(:wait_for_import_snapshot, 'import-task-1', -1)
        }.to raise_error(Bosh::AwsCloud::StemcellCreator::ImportSnapshotTimeout, /Timed out after -1s/)
      end
    end

    describe '#import_snapshot' do
      let(:import_task) { double('import_task', import_task_id: 'import-task-1') }

      before do
        allow(creator).to receive(:wait_for_import_snapshot).and_return('snap-imported')
      end

      it 'builds a RAW disk_container pointing at the S3 object and returns the snapshot id' do
        expect(ec2_client).to receive(:import_snapshot) do |params|
          expect(params[:disk_container][:format]).to eq('RAW')
          expect(params[:disk_container][:url]).to eq('s3://the-bucket/the-key')
          expect(params).not_to have_key(:role_name)
          expect(params).not_to have_key(:encrypted)
          import_task
        end

        expect(creator.send(:import_snapshot, 'the-bucket', 'the-key', nil, false, nil)).to eq('snap-imported')
      end

      it 'passes the import role name when one is configured' do
        expect(ec2_client).to receive(:import_snapshot) do |params|
          expect(params[:role_name]).to eq('vmimport')
          import_task
        end

        creator.send(:import_snapshot, 'the-bucket', 'the-key', 'vmimport', false, nil)
      end

      it 'encrypts with the given KMS key when an ARN is supplied' do
        expect(ec2_client).to receive(:import_snapshot) do |params|
          expect(params[:encrypted]).to be(true)
          expect(params[:kms_key_id]).to eq('arn:aws:kms:us-east-1:ID:key/GUID')
          import_task
        end

        creator.send(:import_snapshot, 'the-bucket', 'the-key', nil, true, 'arn:aws:kms:us-east-1:ID:key/GUID')
      end

      it 'encrypts with the account default key when encryption is requested without an ARN' do
        expect(ec2_client).to receive(:import_snapshot) do |params|
          expect(params[:encrypted]).to be(true)
          expect(params).not_to have_key(:kms_key_id)
          import_task
        end

        creator.send(:import_snapshot, 'the-bucket', 'the-key', nil, true, nil)
      end

      it 'encrypts when an ARN is given even if encrypted is false' do
        expect(ec2_client).to receive(:import_snapshot) do |params|
          expect(params[:encrypted]).to be(true)
          expect(params[:kms_key_id]).to eq('arn:aws:kms:us-east-1:ID:key/GUID')
          import_task
        end

        creator.send(:import_snapshot, 'the-bucket', 'the-key', nil, false, 'arn:aws:kms:us-east-1:ID:key/GUID')
      end

      it 'wraps AWS service errors in a CloudError' do
        allow(ec2_client).to receive(:import_snapshot)
          .and_raise(Aws::Errors::ServiceError.new(nil, 'nope'))

        expect {
          creator.send(:import_snapshot, 'the-bucket', 'the-key', nil, false, nil)
        }.to raise_error(Bosh::Clouds::CloudError, /ImportSnapshot failed: nope/)
      end
    end

    describe '#create_via_import_snapshot' do
      before do
        allow(SecureRandom).to receive(:uuid).and_return('fake-uuid')
      end

      it 'deletes the S3 staging object even when a later step fails' do
        allow(creator).to receive(:upload_root_image_to_s3)
        allow(creator).to receive(:import_snapshot)
          .and_raise(Bosh::Clouds::CloudError, 'import blew up')

        expected_key = 'bosh-stemcell-import/fake-uuid/root.img'
        expect(creator).to receive(:delete_s3_object).with('the-bucket', expected_key)

        expect {
          creator.create_via_import_snapshot('/path/to/image', 'the-bucket')
        }.to raise_error(Bosh::Clouds::CloudError, /import blew up/)
      end

      it 'runs upload -> import -> tag -> register and cleans up on success' do
        stemcell = instance_double(Bosh::AwsCloud::Stemcell)
        expect(creator).to receive(:upload_root_image_to_s3).ordered
        expect(creator).to receive(:import_snapshot).ordered.and_return('snap-imported')
        expect(creator).to receive(:tag_snapshot).with('snap-imported').ordered
        expect(creator).to receive(:register_image_from_snapshot).with('snap-imported').ordered.and_return(stemcell)
        expect(creator).to receive(:delete_s3_object).ordered

        expect(creator.create_via_import_snapshot('/path/to/image', 'the-bucket')).to eq(stemcell)
      end

      it 'does NOT delete the S3 source on a poll timeout (task still running)' do
        allow(creator).to receive(:upload_root_image_to_s3)
        allow(creator).to receive(:import_snapshot)
          .and_raise(Bosh::AwsCloud::StemcellCreator::ImportSnapshotTimeout, 'still running')

        # The whole point of D: a timeout must leave the source in place so the
        # running import is not sabotaged and a retry need not re-upload.
        expect(creator).not_to receive(:delete_s3_object)

        expect {
          creator.create_via_import_snapshot('/path/to/image', 'the-bucket')
        }.to raise_error(Bosh::AwsCloud::StemcellCreator::ImportSnapshotTimeout, /still running/)
      end

      it 'passes a configured timeout through to import_snapshot' do
        stemcell = instance_double(Bosh::AwsCloud::Stemcell)
        allow(creator).to receive(:upload_root_image_to_s3)
        allow(creator).to receive(:tag_snapshot)
        allow(creator).to receive(:register_image_from_snapshot).and_return(stemcell)
        allow(creator).to receive(:delete_s3_object)

        expect(creator).to receive(:import_snapshot)
          .with('the-bucket', anything, nil, false, nil, 7200)
          .and_return('snap-imported')

        creator.create_via_import_snapshot('/path/to/image', 'the-bucket', timeout: 7200)
      end
    end

    describe '#extract_root_image' do
      it 'raises a CloudError when tar exits non-zero' do
        Dir.mktmpdir do |dir|
          dest = File.join(dir, 'root.img')
          # A path that is not a valid tarball makes tar exit non-zero.
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

      it 'does not discard a completed import when tagging hits a transient error' do
        creator.instance_variable_set(:@creation_tags, { 'foo' => 'bar' })
        allow(ec2_resource).to receive(:snapshot).with('snap-imported').and_return(snapshot)
        allow(Bosh::AwsCloud::TagManager).to receive(:create_tags)
          .and_raise(Aws::Errors::ServiceError.new(nil, 'throttled'))

        expect {
          creator.send(:tag_snapshot, 'snap-imported')
        }.not_to raise_error
      end
    end
  end
end
