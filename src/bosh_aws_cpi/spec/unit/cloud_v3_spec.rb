require "spec_helper"

describe Bosh::AwsCloud::CloudV3 do
  subject(:cloud) { described_class.new(options) }

  let(:cloud_core) { instance_double(Bosh::AwsCloud::CloudCore) }
  let(:options) { mock_cloud_options["properties"] }
  let(:az_selector) { instance_double(Bosh::AwsCloud::AvailabilityZoneSelector) }

  before do
    allow(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(az_selector)
  end

  describe "#initialize" do
    context "if stemcell api_version is 3" do
      let(:options) do
        mock_cloud_properties_merge(
          {
            "aws" => {
              "vm" => {
                "stemcell" => {
                  "api_version" => 3,
                },
              },
            },
          }
        )
      end

      it "should initialize cloud_core with agent_version 3" do
        allow(Bosh::AwsCloud::CloudCore).to receive(:new).and_return(cloud_core)
        expect(Bosh::AwsCloud::CloudCore).to receive(:new).with(anything, anything, anything, anything, 3).and_return(cloud_core)
        described_class.new(options)
      end

      context "no stemcell api version in options" do
        let(:options) do
          mock_cloud_properties_merge(
            {
              "aws" => {
                "vm" => {},
              },
            }
          )
        end
        it "should initialize cloud_core with default stemcell api version of 1" do
          allow(Bosh::AwsCloud::CloudCore).to receive(:new).and_return(cloud_core)
          expect(Bosh::AwsCloud::CloudCore).to receive(:new).with(anything, anything, anything, anything, 1).and_return(cloud_core)
          described_class.new(options)
        end
      end
    end
  end

  describe "#create_stemcell" do
    let(:ami_id) { "ami-image-id" }
    let(:image) { instance_double(Aws::EC2::Image, id: ami_id) }
    let(:encrypted_image) { instance_double(Aws::EC2::Image, state: "available", id: "#{ami_id}-copy") }
    let(:image_copy) { instance_double(Aws::EC2::Image, image_id: "#{ami_id}-copy", id: "#{ami_id}-copy") }

    shared_examples "encrypted copy_image behavior" do
      let(:cloud) do
        mock_cloud_v3 do |ec2|
          expect(ec2).to receive(:images).with(
            filters: [{
              name: "image-id",
              values: [ami_id],
            }],
            include_deprecated: true,
          ).and_return([image])

          expect(ec2.client).to receive(:copy_image).with(expected_copy_image_args).and_return(image_copy)

          expect(ec2).to receive(:image).with("ami-image-id-copy").and_return(encrypted_image)

          expect(Bosh::AwsCloud::ResourceWait).to receive(:for_image).with(
            image: encrypted_image,
            state: "available",
          )
        end
      end
    end

    context "for light stemcell" do
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

      let(:cloud) {
        mock_cloud_v3 do |ec2|
          expect(ec2).to receive(:images).with(
            filters: [{
              name: "image-id",
              values: [ami_id],
            }],
            include_deprecated: true,
          ).and_return([image])
        end
      }

      it "if tags are provided" do
        env = { "tags" => { "any" => "value" } }
        expect(Bosh::AwsCloud::TagManager).to receive(:create_tags).with(image, env["tags"])
        cloud.create_stemcell(image, stemcell_properties, env)
      end

      it "if tags are not provided" do
        env = {}
        expect(Bosh::AwsCloud::TagManager).to_not receive(:create_tags)
        cloud.create_stemcell(image, stemcell_properties, env)
      end

      it "if tags are nil" do
        env = { "tags" => nil }
        expect(Bosh::AwsCloud::TagManager).to_not receive(:create_tags)
        cloud.create_stemcell(image, stemcell_properties, env)
      end

      it "if no env is provided" do
        expect(Bosh::AwsCloud::TagManager).to_not receive(:create_tags)
        cloud.create_stemcell(image, stemcell_properties)
      end
    end

    context "with encrypted flag is true" do
      let(:kms_key_arn) { nil }
      let(:stemcell_properties) do
        {
          "encrypted" => true,
          "ami" => {
            "us-east-1" => ami_id,
          },
        }
      end

      context "when env tags are passed for copy_image" do
        let(:expected_copy_image_args) do
          {
            source_region: "us-east-1",
            source_image_id: ami_id,
            name: "Copied from SourceAMI #{ami_id}",
            encrypted: true,
            kms_key_id: kms_key_arn,
            tag_specifications: [
              {
                resource_type: "image",
                tags: [{ key: "any", value: "value" }],
              },
              {
                resource_type: "snapshot",
                tags: [{ key: "any", value: "value" }],
              },
            ],
          }
        end

        include_examples "encrypted copy_image behavior"

        it "applies tag_specifications on copy_image" do
          env = { "tags" => { "any" => "value" } }
          expect(Bosh::AwsCloud::TagManager).to_not receive(:create_tags)
          cloud.create_stemcell(image, stemcell_properties, env)
        end
      end

      context "when no tag_specifications on copy_image" do
        let(:expected_copy_image_args) do
          {
            source_region: "us-east-1",
            source_image_id: ami_id,
            name: "Copied from SourceAMI #{ami_id}",
            encrypted: true,
            kms_key_id: kms_key_arn,
          }
        end

        include_examples "encrypted copy_image behavior"

        it "if tags are not provided" do
          env = {}
          expect(Bosh::AwsCloud::TagManager).to_not receive(:create_tags)
          cloud.create_stemcell(image, stemcell_properties, env)
        end

        it "if tags are nil" do
          env = { "tags" => nil }
          expect(Bosh::AwsCloud::TagManager).to_not receive(:create_tags)
          cloud.create_stemcell(image, stemcell_properties, env)
        end

        it "if no env is provided" do
          expect(Bosh::AwsCloud::TagManager).to_not receive(:create_tags)
          cloud.create_stemcell(image, stemcell_properties)
        end
      end
    end

    context "with kms_key_arn is provided and" do
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

      context "when env tags are passed for copy_image" do
        let(:expected_copy_image_args) do
          {
            source_region: "us-east-1",
            source_image_id: ami_id,
            name: "Copied from SourceAMI #{ami_id}",
            encrypted: true,
            kms_key_id: kms_key_arn,
            tag_specifications: [
              {
                resource_type: "image",
                tags: [{ key: "any", value: "value" }],
              },
              {
                resource_type: "snapshot",
                tags: [{ key: "any", value: "value" }],
              },
            ],
          }
        end

        include_examples "encrypted copy_image behavior"

        it "applies tag_specifications on copy_image" do
          env = { "tags" => { "any" => "value" } }
          expect(Bosh::AwsCloud::TagManager).to_not receive(:create_tags)
          cloud.create_stemcell(image, stemcell_properties, env)
        end
      end

      context "when no tag_specifications on copy_image" do
        let(:expected_copy_image_args) do
          {
            source_region: "us-east-1",
            source_image_id: ami_id,
            name: "Copied from SourceAMI #{ami_id}",
            encrypted: true,
            kms_key_id: kms_key_arn,
          }
        end

        include_examples "encrypted copy_image behavior"

        it "if tags are not provided" do
          env = {}
          expect(Bosh::AwsCloud::TagManager).to_not receive(:create_tags)
          cloud.create_stemcell(image, stemcell_properties, env)
        end

        it "if tags are nil" do
          env = { "tags" => nil }
          expect(Bosh::AwsCloud::TagManager).to_not receive(:create_tags)
          cloud.create_stemcell(image, stemcell_properties, env)
        end

        it "if no env is provided" do
          expect(Bosh::AwsCloud::TagManager).to_not receive(:create_tags)
          cloud.create_stemcell(image, stemcell_properties)
        end
      end
    end

    context "for heavy stemcell" do
      let(:stemcell_properties) do
        {
          "root_device_name" => "/dev/sda1",
          "architecture" => "x86_64",
          "name" => "stemcell-name",
          "version" => "1.2.3",
          "virtualization_type" => "paravirtual",
        }
      end
      let(:cloud) {
        mock_cloud_v3 do |ec2|
          allow(ec2).to receive(:images).with(
            filters: [{
                        name: "image-id",
                        values: [ami_id],
                      }]
          ).and_return([image])
        end
      }
      let(:aws_config) do
        instance_double(Bosh::AwsCloud::AwsConfig, stemcell: {}, encrypted: false, kms_key_arn: nil)
      end
      let(:global_config) { instance_double(Bosh::AwsCloud::Config, aws: aws_config) }
      let(:stemcell_cloud_props) { Bosh::AwsCloud::StemcellCloudProps.new(stemcell_properties, global_config) }
      let(:props_factory) { instance_double(Bosh::AwsCloud::PropsFactory) }

      it "if tags are provided" do
        env = { "tags" => { "any" => "value" } }
        expect(cloud).to receive(:create_ami_for_stemcell).with(
          image,
          instance_of(Bosh::AwsCloud::StemcellCloudProps),
          env["tags"],
        ).and_return(ami_id)
        expect(Bosh::AwsCloud::TagManager).to_not receive(:create_tags)
        expect(cloud.logger).to receive(:info).with(
          "Created stemcell AMI #{ami_id} with env tags applied at resource creation: #{env['tags'].keys.inspect}",
        )
        cloud.create_stemcell(image, stemcell_properties, env)
      end

      it "if tags are not provided" do
        env = {}
        expect(cloud).to receive(:create_ami_for_stemcell).with(
          image,
          instance_of(Bosh::AwsCloud::StemcellCloudProps),
          nil,
        ).and_return(ami_id)
        expect(Bosh::AwsCloud::TagManager).to_not receive(:create_tags)
        cloud.create_stemcell(image, stemcell_properties, env)
      end

      it "if tags are nil" do
        env = { "tags" => nil }
        expect(cloud).to receive(:create_ami_for_stemcell).with(
          image,
          instance_of(Bosh::AwsCloud::StemcellCloudProps),
          nil,
        ).and_return(ami_id)
        expect(Bosh::AwsCloud::TagManager).to_not receive(:create_tags)
        cloud.create_stemcell(image, stemcell_properties, env)
      end

      it "if no env is provided" do
        expect(cloud).to receive(:create_ami_for_stemcell).with(
          image,
          instance_of(Bosh::AwsCloud::StemcellCloudProps),
          nil,
        ).and_return(ami_id)
        expect(Bosh::AwsCloud::TagManager).to_not receive(:create_tags)
        cloud.create_stemcell(image, stemcell_properties)
      end
    end
  end
end
