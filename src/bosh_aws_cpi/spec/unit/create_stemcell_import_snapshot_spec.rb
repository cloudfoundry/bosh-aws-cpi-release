require "spec_helper"

# The ImportSnapshot heavy-stemcell path must be creatable off-EC2
# (e.g. inside a create-env container). These specs assert that when the
# `import_snapshot` stemcell cloud property is set, create_stemcell delegates
# to StemcellCreator#create_via_import_snapshot and NEVER touches the EC2
# metadata endpoint (current_vm_id) or attaches an EBS volume -- the two things
# that make the classic path fail off-EC2.
describe Bosh::AwsCloud::CloudV1 do
  before { @tmp_dir = Dir.mktmpdir }
  after { FileUtils.rm_rf(@tmp_dir) }

  describe "ImportSnapshot based flow" do
    let(:creator) { instance_double(Bosh::AwsCloud::StemcellCreator) }
    let(:volume_manager) { instance_double(Bosh::AwsCloud::VolumeManager) }
    let(:az_selector) do
      instance_double(Bosh::AwsCloud::AvailabilityZoneSelector, select_availability_zone: "us-east-1a")
    end
    let(:stemcell) { instance_double(Bosh::AwsCloud::Stemcell, :id => "ami-imported") }

    let(:stemcell_properties) do
      {
        "root_device_name" => "/dev/xvda",
        "architecture" => "x86_64",
        "name" => "stemcell-name",
        "version" => "1.2.3",
        "virtualization_type" => "hvm",
        "import_snapshot" => { "bucket" => "my-stemcell-bucket", "role_name" => "vmimport" },
      }
    end

    let(:aws_config) do
      instance_double(Bosh::AwsCloud::AwsConfig, stemcell: {}, encrypted: false, kms_key_arn: nil)
    end
    let(:global_config) { instance_double(Bosh::AwsCloud::Config, aws: aws_config) }
    let(:stemcell_cloud_props) { Bosh::AwsCloud::StemcellCloudProps.new(stemcell_properties, global_config) }
    let(:props_factory) { instance_double(Bosh::AwsCloud::PropsFactory) }

    before do
      allow(Bosh::AwsCloud::PropsFactory).to receive(:new).and_return(props_factory)
      allow(props_factory).to receive(:stemcell_props)
          .with(stemcell_properties)
          .and_return(stemcell_cloud_props)
    end

    it "creates a stemcell via ImportSnapshot without touching EC2 metadata or EBS" do
      cloud = mock_cloud do |ec2|
        expect(Bosh::AwsCloud::StemcellCreator).to receive(:new)
            .with(ec2, stemcell_cloud_props)
            .and_return(creator)
        allow(Bosh::AwsCloud::VolumeManager).to receive(:new).and_return(volume_manager)
        allow(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(az_selector)
      end

      # The whole point of the import-snapshot path: none of these may be
      # invoked off-EC2.
      expect(cloud).not_to receive(:current_vm_id)
      expect(volume_manager).not_to receive(:create_ebs_volume)
      expect(volume_manager).not_to receive(:attach_ebs_volume)

      expect(creator).to receive(:create_via_import_snapshot).with(
        "/tmp/foo",
        "my-stemcell-bucket",
        import_role_name: "vmimport",
        encrypted: false,
        kms_key_arn: nil,
        tags: {},
      ).and_return(stemcell)

      expect(cloud.create_stemcell("/tmp/foo", stemcell_properties)).to eq("ami-imported")
    end

    it "forwards the kms_key_arn to the creator when encryption is requested" do
      encrypted_properties = stemcell_properties.merge(
        "encrypted" => true,
        "kms_key_arn" => "arn:aws:kms:us-east-1:ID:key/GUID",
      )
      encrypted_cloud_props = Bosh::AwsCloud::StemcellCloudProps.new(encrypted_properties, global_config)

      allow(props_factory).to receive(:stemcell_props)
          .with(encrypted_properties)
          .and_return(encrypted_cloud_props)

      cloud = mock_cloud do |ec2|
        expect(Bosh::AwsCloud::StemcellCreator).to receive(:new)
            .with(ec2, encrypted_cloud_props)
            .and_return(creator)
        allow(Bosh::AwsCloud::VolumeManager).to receive(:new).and_return(volume_manager)
        allow(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(az_selector)
      end

      expect(cloud).not_to receive(:current_vm_id)

      expect(creator).to receive(:create_via_import_snapshot).with(
        "/tmp/foo",
        "my-stemcell-bucket",
        import_role_name: "vmimport",
        encrypted: true,
        kms_key_arn: "arn:aws:kms:us-east-1:ID:key/GUID",
        tags: {},
      ).and_return(stemcell)

      expect(cloud.create_stemcell("/tmp/foo", encrypted_properties)).to eq("ami-imported")
    end

    it "raises when import_snapshot is requested without an S3 bucket" do
      bad_properties = stemcell_properties.merge("import_snapshot" => { "role_name" => "vmimport" })
      bad_cloud_props = Bosh::AwsCloud::StemcellCloudProps.new(bad_properties, global_config)

      allow(props_factory).to receive(:stemcell_props)
          .with(bad_properties)
          .and_return(bad_cloud_props)

      cloud = mock_cloud do |ec2|
        allow(Bosh::AwsCloud::StemcellCreator).to receive(:new).and_return(creator)
        allow(Bosh::AwsCloud::VolumeManager).to receive(:new).and_return(volume_manager)
        allow(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(az_selector)
      end

      expect(creator).not_to receive(:create_via_import_snapshot)

      expect {
        cloud.create_stemcell("/tmp/foo", bad_properties)
      }.to raise_error(/import_snapshot requires an S3 bucket/)
    end

    it "falls back to the classic EBS path when import_snapshot is not set" do
      classic_properties = {
        "root_device_name" => "/dev/xvda",
        "architecture" => "x86_64",
        "name" => "stemcell-name",
        "version" => "1.2.3",
        "virtualization_type" => "hvm",
      }
      classic_cloud_props = Bosh::AwsCloud::StemcellCloudProps.new(classic_properties, global_config)

      allow(props_factory).to receive(:stemcell_props)
          .with(classic_properties)
          .and_return(classic_cloud_props)

      cloud = mock_cloud do |ec2|
        allow(Bosh::AwsCloud::StemcellCreator).to receive(:new).and_return(creator)
        allow(Bosh::AwsCloud::VolumeManager).to receive(:new).and_return(volume_manager)
        allow(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(az_selector)
      end

      expect(creator).not_to receive(:create_via_import_snapshot)
      # classic path begins with current_vm_id; stub it so the test does not
      # reach the real metadata endpoint, and assert it IS consulted.
      expect(cloud).to receive(:current_vm_id).and_raise(
        Bosh::Clouds::CloudError.new("Timed out reading instance metadata, please make sure CPI is running on EC2 instance")
      )

      expect {
        cloud.create_stemcell("/tmp/foo", classic_properties)
      }.to raise_error(/Timed out reading instance metadata/)
    end
  end
end
