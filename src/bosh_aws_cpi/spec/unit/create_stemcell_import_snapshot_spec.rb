require "spec_helper"

# The ImportSnapshot heavy-stemcell path must be creatable off-EC2
# (e.g. inside a create-env container). These specs assert that when the
# `import_snapshot` config is set, create_stemcell delegates to
# StemcellCreator#create_via_import_snapshot and NEVER touches the EC2
# metadata endpoint (current_vm_id) or attaches an EBS volume -- the two things
# that make the classic path fail off-EC2.
#
# The opt-in is landscape-specific (which S3 staging bucket, which VM
# Import/Export role), so its only home is the CPI's global config
# (`cloud_provider.properties.aws.stemcell.import_snapshot`), which reaches the
# CPI as `config.aws.stemcell['import_snapshot']`. It is the same for every
# stemcell in a given director and is NOT baked into the (shared) stemcell
# tarball.
#
# NOTE: `mock_cloud` builds a *real* Config/AwsConfig/PropsFactory from the
# options hash, so `import_snapshot` is injected via aws.stemcell in the CPI
# options (NOT via test doubles). Only StemcellCreator -- the external AWS
# boundary -- is stubbed.
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

    # Plain heavy-stemcell props with NO per-stemcell import_snapshot; the
    # opt-in comes from the global aws.stemcell config injected via mock_cloud.
    let(:stemcell_properties) do
      {
        "root_device_name" => "/dev/xvda",
        "architecture" => "x86_64",
        "name" => "stemcell-name",
        "version" => "1.2.3",
        "virtualization_type" => "hvm",
      }
    end

    # Landscape-specific import_snapshot config, as it arrives from
    # cloud_provider.properties.aws.stemcell.import_snapshot.
    def cloud_with_global_import_snapshot(import_snapshot, aws_overrides = {})
      options = mock_cloud_properties_merge(
        "aws" => { "stemcell" => { "import_snapshot" => import_snapshot } }.merge(aws_overrides),
      )
      mock_cloud(options) do |ec2|
        allow(Bosh::AwsCloud::StemcellCreator).to receive(:new).and_return(creator)
        allow(Bosh::AwsCloud::VolumeManager).to receive(:new).and_return(volume_manager)
        allow(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(az_selector)
        yield ec2 if block_given?
      end
    end

    it "creates a stemcell via ImportSnapshot (opt-in from global aws.stemcell config) without touching EC2 metadata or EBS" do
      cloud = cloud_with_global_import_snapshot("bucket" => "my-stemcell-bucket", "role_name" => "vmimport")

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
      cloud = cloud_with_global_import_snapshot("bucket" => "my-stemcell-bucket", "role_name" => "vmimport")

      encrypted_properties = stemcell_properties.merge(
        "encrypted" => true,
        "kms_key_arn" => "arn:aws:kms:us-east-1:ID:key/GUID",
      )

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
      cloud = cloud_with_global_import_snapshot("role_name" => "vmimport")

      expect(creator).not_to receive(:create_via_import_snapshot)

      expect {
        cloud.create_stemcell("/tmp/foo", stemcell_properties)
      }.to raise_error(/import_snapshot requires an S3 bucket/)
    end

    it "falls back to the classic EBS path when import_snapshot is not configured" do
      cloud = mock_cloud do
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
        cloud.create_stemcell("/tmp/foo", stemcell_properties)
      }.to raise_error(/Timed out reading instance metadata/)
    end
  end
end
