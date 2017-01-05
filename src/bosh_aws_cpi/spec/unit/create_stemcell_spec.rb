require "spec_helper"

describe Bosh::AwsCloud::Cloud do
  before { @tmp_dir = Dir.mktmpdir }
  after { FileUtils.rm_rf(@tmp_dir) }

  describe "EBS-volume based flow" do
    let(:creator) { double(Bosh::AwsCloud::StemcellCreator) }

    context "light stemcell" do
      let(:stemcell_properties) do
        {
          "root_device_name" => "/dev/sda1",
          "architecture" => "x86_64",
          "name" => "stemcell-name",
          "version" => "1.2.3",
          "ami" => {
            "us-east-1" => "ami-xxxxxxxx"
          }
        }
      end

      it "should return a light stemcell" do
        cloud = mock_cloud do |ec2|
          allow(ec2).to receive(:images).with({
            filters: [{
              name: 'image-id',
              values: ['ami-xxxxxxxx'],
            }],
          }).and_return([double('image', id: 'ami-xxxxxxxx')])
        end
        expect(cloud.create_stemcell("/tmp/foo", stemcell_properties)).to eq("ami-xxxxxxxx light")
      end
    end

    context "real stemcell" do
      let(:stemcell_properties) do
        {
          "root_device_name" => "/dev/sda1",
          "architecture" => "x86_64",
          "name" => "stemcell-name",
          "version" => "1.2.3",
          "virtualization_type" => "paravirtual"
        }
      end

      let(:volume) { double("volume", :id => "vol-xxxxxxxx") }
      let(:stemcell) { double("stemcell", :id => "ami-xxxxxxxx") }
      let(:instance) { double("instance") }

      it "should create a stemcell" do
        cloud = mock_cloud do |ec2|
          allow(ec2).to receive(:volume).with("vol-xxxxxxxx").and_return(volume)
          allow(ec2).to receive(:instance).with("i-xxxxxxxx").and_return(instance)

          expect(Bosh::AwsCloud::StemcellCreator).to receive(:new)
            .with(ec2, stemcell_properties)
            .and_return(creator)
        end

        allow(instance).to receive(:exists?).and_return(true)
        allow(cloud).to receive(:current_vm_id).and_return("i-xxxxxxxx")

        expect(cloud).to receive(:create_disk).with(2048, {}, "i-xxxxxxxx").and_return("vol-xxxxxxxx")
        expect(cloud).to receive(:attach_ebs_volume).with(instance, volume).and_return("/dev/sdh")
        expect(cloud).to receive(:find_device_path_by_name).with("/dev/sdh").and_return("ebs")

        expect(creator).to receive(:create).with(volume, "ebs", "/tmp/foo").and_return(stemcell)

        expect(cloud).to receive(:detach_ebs_volume).with(instance, volume, true)
        expect(cloud).to receive(:delete_disk).with("vol-xxxxxxxx")

        expect(cloud.create_stemcell("/tmp/foo", stemcell_properties)).to eq("ami-xxxxxxxx")
      end

      context 'when the CPI configuration includes a kernel_id for stemcell' do
        it "creates a stemcell" do
          options = mock_cloud_options['properties']
          options['aws']['stemcell'] = {'kernel_id' => 'fake-kernel-id'}
          cloud = mock_cloud(options) do |ec2|
            allow(ec2).to receive(:volume).with("vol-xxxxxxxx").and_return(volume)
            allow(ec2).to receive(:instance).with("i-xxxxxxxx").and_return(instance)

            expect(Bosh::AwsCloud::StemcellCreator).to receive(:new)
              .with(ec2, stemcell_properties.merge('kernel_id' => 'fake-kernel-id'))
              .and_return(creator)
          end

          allow(instance).to receive(:exists?).and_return(true)
          allow(cloud).to receive(:current_vm_id).and_return("i-xxxxxxxx")

          expect(cloud).to receive(:create_disk).with(2048, {}, "i-xxxxxxxx").and_return("vol-xxxxxxxx")
          expect(cloud).to receive(:attach_ebs_volume).with(instance, volume).and_return("/dev/sdh")
          expect(cloud).to receive(:find_device_path_by_name).with("/dev/sdh").and_return("ebs")

          allow(creator).to receive(:create)
          expect(creator).to receive(:create).with(volume, "ebs", "/tmp/foo").and_return(stemcell)

          expect(cloud).to receive(:detach_ebs_volume).with(instance, volume, true)
          expect(cloud).to receive(:delete_disk).with("vol-xxxxxxxx")

          expect(cloud.create_stemcell("/tmp/foo", stemcell_properties)).to eq("ami-xxxxxxxx")
        end
      end
    end

    describe "#find_device_path_by_name" do
      it "should locate ebs volume on the current instance and return the device name" do
        cloud = mock_cloud

        allow(File).to receive(:blockdev?).with("/dev/sdf").and_return(true)

        expect(cloud.find_device_path_by_name("/dev/sdf")).to eq("/dev/sdf")
      end

      it "should locate ebs volume on the current instance and return the virtual device name" do
        cloud = mock_cloud

        allow(File).to receive(:blockdev?).with("/dev/sdf").and_return(false)
        allow(File).to receive(:blockdev?).with("/dev/xvdf").and_return(true)

        expect(cloud.find_device_path_by_name("/dev/sdf")).to eq("/dev/xvdf")
      end
    end
  end
end
