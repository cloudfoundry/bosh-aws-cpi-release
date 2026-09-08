require "spec_helper"

describe Bosh::AwsCloud::CloudV1 do
  before { @tmp_dir = Dir.mktmpdir }
  after { FileUtils.rm_rf(@tmp_dir) }

  describe "create_stemcell" do
    let(:creator) { double(Bosh::AwsCloud::StemcellCreator) }

    context "light stemcell" do
      let(:ami_id) { "ami-xxxxxxxx" }
      let(:encrypted_ami) { instance_double(Aws::EC2::Image, state: "available") }
      let(:stemcell_properties) do
        {
          "root_device_name" => "/dev/sda1",
          "architecture" => "x86_64",
          "name" => "stemcell-name",
          "version" => "1.2.3",
          "ami" => {
            "us-east-1" => ami_id,
          },
        }
      end

      it "should return a light stemcell" do
        cloud = mock_cloud do |ec2|
          expect(ec2).to receive(:images).with(
            filters: [{
              name: "image-id",
              values: [ami_id],
            }],
            include_deprecated: true,
          ).and_return([double("image", id: ami_id)])
        end
        expect(cloud.create_stemcell("/tmp/foo", stemcell_properties)).to eq("#{ami_id} light")
      end

      context "when encrypted flag is true" do
        let(:kms_key_arn) { nil }
        let(:stemcell_properties) do
          {
            "encrypted" => true,
            "ami" => {
              "us-east-1" => ami_id,
            },
          }
        end

        it "should copy ami" do
          cloud = mock_cloud do |ec2|
            expect(ec2).to receive(:images).with(
              filters: [{
                name: "image-id",
                values: [ami_id],
              }],
              include_deprecated: true,
            ).and_return([double("image", id: ami_id)])

            expect(ec2.client).to receive(:copy_image).with(
              source_region: "us-east-1",
              source_image_id: ami_id,
              name: "Copied from SourceAMI #{ami_id}",
              encrypted: true,
              kms_key_id: kms_key_arn,
            ).and_return(double("copy_image_result", image_id: "ami-newami"))

            expect(ec2).to receive(:image).with("ami-newami").and_return(encrypted_ami)

            expect(Bosh::AwsCloud::ResourceWait).to receive(:for_image).with(
              image: encrypted_ami,
              state: "available",
            )
          end

          cloud.create_stemcell("/tmp/foo", stemcell_properties)
        end

        it "should return stemcell id (not light stemcell id)" do
          cloud = mock_cloud do |ec2, _client|
            expect(ec2).to receive(:images).with(
              filters: [{
                name: "image-id",
                values: [ami_id],
              }],
              include_deprecated: true,
            ).and_return([double("image", id: ami_id)])

            expect(ec2.client).to receive(:copy_image).with(
              source_region: "us-east-1",
              source_image_id: ami_id,
              name: "Copied from SourceAMI #{ami_id}",
              encrypted: true,
              kms_key_id: kms_key_arn,
            ).and_return(double("copy_image_result", image_id: "ami-newami"))

            expect(ec2).to receive(:image).with("ami-newami").and_return(encrypted_ami)

            expect(Bosh::AwsCloud::ResourceWait).to receive(:for_image).with(
              image: encrypted_ami,
              state: "available",
            )
          end

          expect(cloud.create_stemcell("/tmp/foo", stemcell_properties)).to eq("ami-newami")
        end
      end

      context "and kms_key_arn is given" do
        let(:kms_key_arn) { "arn:aws:kms:us-east-1:12345678:key/guid" }
        let(:stemcell_properties) do
          {
            "encrypted" => true,
            "kms_key_arn" => kms_key_arn,
            "ami" => {
              "us-east-1" => ami_id,
            },
          }
        end

        it "should encrypt ami with given kms_key_arn" do
          cloud = mock_cloud do |ec2, _client|
            expect(ec2).to receive(:images).with(
              filters: [{
                name: "image-id",
                values: [ami_id],
              }],
              include_deprecated: true,
            ).and_return([double("image", id: ami_id)])

            expect(ec2.client).to receive(:copy_image).with(
              source_region: "us-east-1",
              source_image_id: ami_id,
              name: "Copied from SourceAMI #{ami_id}",
              encrypted: true,
              kms_key_id: kms_key_arn,
            ).and_return(double("copy_image_result", image_id: "ami-newami"))

            expect(ec2).to receive(:image).with("ami-newami").and_return(encrypted_ami)

            expect(Bosh::AwsCloud::ResourceWait).to receive(:for_image).with(
              image: encrypted_ami,
              state: "available",
            )
          end

          cloud.create_stemcell("/tmp/foo", stemcell_properties)
        end
      end

      context "when ami does NOT exist" do
        it "should return error" do
          cloud = mock_cloud do |ec2|
            allow(ec2).to receive(:images).with(
              filters: [{
                name: "image-id",
                values: ["ami-xxxxxxxx"],
              }],
              include_deprecated: true,
            ).and_return([])
          end
          expect {
            cloud.create_stemcell("/tmp/foo", stemcell_properties)
          }.to raise_error(/Stemcell does not contain an AMI in region/)
        end
      end
    end

    context "heavy stemcell" do
      let(:stemcell_properties) do
        {
          "root_device_name" => "/dev/sda1",
          "architecture" => "x86_64",
          "name" => "stemcell-name",
          "version" => "1.2.3",
          "virtualization_type" => "paravirtual",
        }
      end
      let(:stemcell) { instance_double(Bosh::AwsCloud::Stemcell, :id => "ami-xxxxxxxx") }
      let(:aws_config) do
        instance_double(Bosh::AwsCloud::AwsConfig, stemcell: {}, encrypted: false, kms_key_arn: nil)
      end
      let(:global_config) { instance_double(Bosh::AwsCloud::Config, aws: aws_config) }
      let(:stemcell_cloud_props) { Bosh::AwsCloud::StemcellCloudProps.new(stemcell_properties, global_config) }
      let(:props_factory) { instance_double(Bosh::AwsCloud::PropsFactory) }

      before do
        allow(Bosh::AwsCloud::PropsFactory).to receive(:new)
            .and_return(props_factory)
        allow(props_factory).to receive(:stemcell_props)
            .with(stemcell_properties)
            .and_return(stemcell_cloud_props)
      end

      it "routes to the EBS-direct creator and returns the AMI id" do
        cloud = mock_cloud do |ec2|
          expect(Bosh::AwsCloud::StemcellCreator).to receive(:new)
              .with(ec2, stemcell_cloud_props)
              .and_return(creator)
        end

        expect(creator).to receive(:create).with(
          "/tmp/foo",
          encrypted: false,
          kms_key_arn: nil,
          tags: {},
        ).and_return(stemcell)

        expect(cloud.create_stemcell("/tmp/foo", stemcell_properties)).to eq("ami-xxxxxxxx")
      end

      it "sets tags to an empty Hash when no tags key is present in cloud properties" do
        expect(stemcell_cloud_props.tags).to eq({})
      end

      it "forwards cloud-property tags to the EBS-direct creator" do
        tags = { "env" => "test", "owner" => "bosh" }
        tagged_properties = stemcell_properties.merge("tags" => tags)
        tagged_cloud_props = Bosh::AwsCloud::StemcellCloudProps.new(tagged_properties, global_config)

        allow(props_factory).to receive(:stemcell_props)
            .with(tagged_properties)
            .and_return(tagged_cloud_props)

        cloud = mock_cloud do |ec2|
          expect(Bosh::AwsCloud::StemcellCreator).to receive(:new)
              .with(ec2, tagged_cloud_props)
              .and_return(creator)
        end

        expect(creator).to receive(:create).with(
          "/tmp/foo",
          encrypted: false,
          kms_key_arn: nil,
          tags: tags,
        ).and_return(stemcell)

        expect(cloud.create_stemcell("/tmp/foo", tagged_properties)).to eq("ami-xxxxxxxx")
      end

      it "creates a stemcell via EBS direct without touching EC2 metadata or EBS" do
        volume_manager = instance_double(Bosh::AwsCloud::VolumeManager)
        cloud = mock_cloud do
          allow(Bosh::AwsCloud::StemcellCreator).to receive(:new).and_return(creator)
          allow(Bosh::AwsCloud::VolumeManager).to receive(:new).and_return(volume_manager)
        end

        expect(cloud).not_to receive(:current_vm_id)
        expect(volume_manager).not_to receive(:create_ebs_volume)
        expect(volume_manager).not_to receive(:attach_ebs_volume)

        expect(creator).to receive(:create).with(
          "/tmp/foo",
          encrypted: false,
          kms_key_arn: nil,
          tags: {},
        ).and_return(stemcell)

        expect(cloud.create_stemcell("/tmp/foo", stemcell_properties)).to eq("ami-xxxxxxxx")
      end

      it "forwards encrypted/kms_key_arn cloud properties to the EBS-direct creator" do
        props_with_enc = stemcell_properties.merge(
          "encrypted" => true,
          "kms_key_arn" => "arn:aws:kms:us-east-1:ID:key/GUID",
        )
        cloud_props_enc = Bosh::AwsCloud::StemcellCloudProps.new(
          props_with_enc,
          instance_double(Bosh::AwsCloud::Config, aws:
            instance_double(Bosh::AwsCloud::AwsConfig, stemcell: {}, encrypted: true,
              kms_key_arn: "arn:aws:kms:us-east-1:ID:key/GUID")),
        )
        allow(props_factory).to receive(:stemcell_props)
            .with(props_with_enc)
            .and_return(cloud_props_enc)

        stemcell_enc = instance_double(Bosh::AwsCloud::Stemcell, :id => "ami-enc")
        cloud = mock_cloud do |ec2|
          expect(Bosh::AwsCloud::StemcellCreator).to receive(:new)
              .with(ec2, cloud_props_enc)
              .and_return(creator)
        end

        expect(creator).to receive(:create).with(
          "/tmp/foo",
          encrypted: true,
          kms_key_arn: "arn:aws:kms:us-east-1:ID:key/GUID",
          tags: {},
        ).and_return(stemcell_enc)

        expect(cloud.create_stemcell("/tmp/foo", props_with_enc)).to eq("ami-enc")
      end

      context "when encryption information is incomplete" do
        it "passes encrypted: false when encrypted=false and kms_key_arn is provided" do
          props = stemcell_properties.merge(
            "encrypted" => false,
            "kms_key_arn" => "arn:aws:kms:us-east-1:ID:key/GUID",
          )
          cloud_props = Bosh::AwsCloud::StemcellCloudProps.new(
            props,
            instance_double(Bosh::AwsCloud::Config, aws:
              instance_double(Bosh::AwsCloud::AwsConfig, stemcell: {}, encrypted: false,
                kms_key_arn: "arn:aws:kms:us-east-1:ID:key/GUID")),
          )
          allow(props_factory).to receive(:stemcell_props).with(props).and_return(cloud_props)

          cloud = mock_cloud do |ec2|
            expect(Bosh::AwsCloud::StemcellCreator).to receive(:new)
                .with(ec2, cloud_props).and_return(creator)
          end

          expect(creator).to receive(:create).with(
            "/tmp/foo",
            encrypted: false,
            kms_key_arn: "arn:aws:kms:us-east-1:ID:key/GUID",
            tags: {},
          ).and_return(stemcell)

          expect(cloud.create_stemcell("/tmp/foo", props)).to eq("ami-xxxxxxxx")
        end

        it "passes encrypted: false when encrypted is absent and kms_key_arn is provided" do
          props = stemcell_properties.merge(
            "kms_key_arn" => "arn:aws:kms:us-east-1:ID:key/GUID",
          )
          cloud_props = Bosh::AwsCloud::StemcellCloudProps.new(
            props,
            instance_double(Bosh::AwsCloud::Config, aws:
              instance_double(Bosh::AwsCloud::AwsConfig, stemcell: {}, encrypted: false,
                kms_key_arn: "arn:aws:kms:us-east-1:ID:key/GUID")),
          )
          allow(props_factory).to receive(:stemcell_props).with(props).and_return(cloud_props)

          cloud = mock_cloud do |ec2|
            expect(Bosh::AwsCloud::StemcellCreator).to receive(:new)
                .with(ec2, cloud_props).and_return(creator)
          end

          expect(creator).to receive(:create).with(
            "/tmp/foo",
            encrypted: false,
            kms_key_arn: "arn:aws:kms:us-east-1:ID:key/GUID",
            tags: {},
          ).and_return(stemcell)

          expect(cloud.create_stemcell("/tmp/foo", props)).to eq("ami-xxxxxxxx")
        end
      end
    end
  end
end
