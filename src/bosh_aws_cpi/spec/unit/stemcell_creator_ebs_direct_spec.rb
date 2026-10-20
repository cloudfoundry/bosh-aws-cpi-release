require 'spec_helper'

module Bosh::AwsCloud
  describe StemcellCreator do
    let(:ec2_client)   { instance_double(Aws::EC2::Client) }
    let(:ec2_resource) { instance_double(Aws::EC2::Resource, client: ec2_client) }
    let(:ebs_client)   { instance_double(Aws::EBS::Client) }
    let(:ebs_uploader) { instance_double(Bosh::AwsCloud::EbsDirectUploader) }
    let(:aws_config) do
      instance_double(Bosh::AwsCloud::AwsConfig,
        stemcell: {}, encrypted: false, kms_key_arn: nil,
        credentials: nil, max_retries: 3, dualstack: false, region: 'us-east-1')
    end
    let(:global_config) { instance_double(Bosh::AwsCloud::Config, aws: aws_config) }
    let(:properties) do
      {
        'name'              => 'stemcell-name',
        'version'           => '0.7.0',
        'infrastructure'    => 'aws',
        'architecture'      => 'x86_64',
        'root_device_name'  => '/dev/xvda',
        'virtualization_type' => 'hvm',
        'disk'              => 1024,
      }
    end
    let(:stemcell_cloud_props) { Bosh::AwsCloud::StemcellCloudProps.new(properties, global_config) }
    let(:creator) { described_class.new(ec2_resource, stemcell_cloud_props, ebs_client) }

    before do
      allow(Bosh::AwsCloud::EbsDirectUploader).to receive(:new).and_return(ebs_uploader)
    end

    # create streams the root image through stream_root_image, which yields the
    # tar pipe IO and returns whatever the block returns (the snapshot id). Stub
    # it to yield a dummy IO so the uploader expectations drive the test.
    def stub_stream_yielding(io = instance_double(IO))
      allow(creator).to receive(:stream_root_image) do |_image_path, &blk|
        blk.call(io)
      end
    end

    describe '#create' do
      it 'streams the root image, uploads via EbsDirectUploader, and registers the AMI' do
        stemcell = instance_double(Bosh::AwsCloud::Stemcell)
        stub_stream_yielding
        allow(creator).to receive(:compute_volume_size_gib).and_return(2)
        expect(ebs_uploader).to receive(:upload).with(
          anything,
          volume_size_gib: 2,
          encrypted:       false,
          kms_key_arn:     nil,
          tags:            nil,
        ).and_return('snap-ebs')
        expect(creator).to receive(:register_image_from_snapshot).with('snap-ebs').and_return(stemcell)

        expect(creator.create('/path/to/image.tgz')).to eq(stemcell)
      end

      it 'forwards encrypted and kms_key_arn to the uploader' do
        stub_stream_yielding
        allow(creator).to receive(:compute_volume_size_gib).and_return(2)
        allow(creator).to receive(:register_image_from_snapshot).and_return(instance_double(Bosh::AwsCloud::Stemcell))

        expect(ebs_uploader).to receive(:upload).with(
          anything,
          volume_size_gib: 2,
          encrypted:       true,
          kms_key_arn:     'arn:aws:kms:us-east-1:ID:key/GUID',
          tags:            nil,
        ).and_return('snap-enc')

        creator.create('/path/to/image.tgz', encrypted: true, kms_key_arn: 'arn:aws:kms:us-east-1:ID:key/GUID')
      end

      it 'passes tags to the uploader' do
        tags = { 'env' => 'test', 'owner' => 'bosh' }
        stub_stream_yielding
        allow(creator).to receive(:compute_volume_size_gib).and_return(2)
        allow(creator).to receive(:register_image_from_snapshot).and_return(instance_double(Bosh::AwsCloud::Stemcell))

        expect(ebs_uploader).to receive(:upload).with(
          anything,
          volume_size_gib: 2,
          encrypted:       false,
          kms_key_arn:     nil,
          tags:            tags,
        ).and_return('snap-tagged')

        creator.create('/path/to/image.tgz', tags: tags)
      end
    end

    describe '#compute_volume_size_gib' do
      it 'sizes the volume from the stemcell disk property (ceiling GiB, min 1)' do
        # disk is 1024 MiB in the fixture -> 1 GiB
        expect(creator.send(:compute_volume_size_gib)).to eq(1)
      end
    end

    describe '#stream_root_image' do
      it 'raises a CloudError when tar exits non-zero' do
        Dir.mktmpdir do |dir|
          bogus = File.join(dir, 'not-a-tarball.tgz')
          File.write(bogus, 'this is not a gzip tarball')

          expect {
            creator.send(:stream_root_image, bogus) { |io| io.read }
          }.to raise_error(Bosh::Clouds::CloudError, /Unable to extract stemcell root image/)
        end
      end
    end
  end
end
