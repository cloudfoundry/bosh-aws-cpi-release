require 'spec_helper'

module Bosh::AwsCloud
  describe StemcellCreator do
    let(:region) { double("region", :name => "us-east-1") }
    let(:properties) do
      {
          "name" => "stemcell-name",
          "version" => "0.7.0",
          "infrastructure" => "aws",
          "architecture" =>  "x86_64",
          "root_device_name" => "/dev/sda1",
          "virtualization_type" => virtualization_type
      }
    end

    let(:virtualization_type) { "paravirtual" }

    before do
      allow(Bosh::AwsCloud::AKIPicker).to receive(:new).and_return(double("aki", :pick => "aki-xxxxxxxx"))
    end

    let(:volume) { double("volume") }
    let(:snapshot) { double("snapshot", :id => "snap-xxxxxxxx") }
    let(:image_id) { "ami-a1b2c3d4" }
    let(:image) { double("image", :id => image_id) }
    let(:device_path) { double("device_path") }

    it "should create a real stemcell" do
      creator = described_class.new(region, properties)
      allow(Bosh::AwsCloud::ResourceWait).to receive(:for_snapshot).with(snapshot: snapshot, state: 'completed')
      allow(Bosh::AwsCloud::ResourceWait).to receive(:for_image).with(image: image, state: 'available')
      allow(SecureRandom).to receive(:uuid).and_return("fake-uuid")
      allow(region).to receive(:images).and_return({
        image_id => image,
      })
      allow(region).to receive_message_chain(:client, :register_image).and_return(double("object", :image_id => image_id))

      expect(creator).to receive(:copy_root_image)
      expect(volume).to receive(:create_snapshot).and_return(snapshot)
      expect(Bosh::AwsCloud::TagManager).to receive(:tag).with(image, "Name", "stemcell-name 0.7.0")

      creator.create(volume, device_path, "/path/to/image")
    end

    describe "#image_params" do
      context "when virtualization type is paravirtual, and no kernel_id is specified" do
        let(:virtualization_type) { "paravirtual" }

        before do
          properties.delete('kernel_id')
        end

        it "constructs correct image params" do
          params = StemcellCreator.new(region, properties).image_params("id")

          expect(params[:architecture]).to eq("x86_64")
          expect(params[:description]).to eq("stemcell-name 0.7.0")
          expect(params[:kernel_id]).to eq("aki-xxxxxxxx")
          expect(params[:root_device_name]).to eq("/dev/sda1")
          expect(params[:block_device_mappings]).to eq([
            {
              :device_name => "/dev/sda",
              :ebs => {
                :snapshot_id => "id",
              },
            },
            {
              :device_name => "/dev/sdb",
              :virtual_name => "ephemeral0",
            },
          ])
        end
      end

      context "when virtualization is paravirtual, and kernel_id is specified" do
        let(:virtualization_type) { "paravirtual" }

        before do
          properties['kernel_id'] = 'aki-zzzzzzzz'
        end

        it 'constructs the image params, including the specified kernel_id' do
          params = StemcellCreator.new(region, properties).image_params('id')
          expect(params[:kernel_id]).to eq("aki-zzzzzzzz")
        end
      end

      context "when the virtualization type is hvm" do
        let(:virtualization_type) { "hvm" }

        it "should construct correct image params" do
          params = described_class.new(region, properties).image_params("id")

          expect(params[:architecture]).to eq("x86_64")
          expect(params[:description]).to eq("stemcell-name 0.7.0")
          expect(params).not_to have_key(:kernel_id)
          expect(params[:root_device_name]).to eq("/dev/xvda")
          expect(params[:sriov_net_support]).to eq("simple")
          expect(params[:block_device_mappings]).to eq([
            {
              :device_name => "/dev/xvda",
              :ebs => {
                :snapshot_id => "id",
              },
            },
            {
              :device_name => "/dev/sdb",
              :virtual_name => "ephemeral0",
            },
          ])
          expect(params[:virtualization_type]).to eq("hvm")
        end
      end
    end

    describe "#find_in_path" do
      it "should not find a missing file" do
        creator = described_class.new(region, properties)
        expect(creator.find_in_path("some_non_existant_file")).to be_nil
      end

      it "should find stemcell-copy" do
        Dir.mktmpdir do |dir|
          ENV["PATH"] += ":#{dir}"
          f = File.open(File.join(dir, 'fake-stemcell-copy'), 'w')
          filename = f.path
          f.close
          creator = described_class.new(region, properties)
          expect(creator.find_in_path(File.basename('fake-stemcell-copy'))).to eq(filename)
        end
      end
    end

    describe '#copy_root_image' do
      let(:creator) do
        creator = described_class.new(region, properties)
        allow(creator).to receive(:image_path).and_return('/path/to/image')
        allow(creator).to receive(:device_path).and_return('/dev/volume')
        creator
      end

      it 'should call stemcell-copy found in the PATH' do
        allow(creator).to receive(:find_in_path).and_return('/path/to/stemcell-copy')
        result = double('result', :output => 'output')

        cmd = 'sudo -n /path/to/stemcell-copy /path/to/image /dev/volume 2>&1'
        expect(creator).to receive(:sh).with(cmd).and_return(result)

        creator.copy_root_image
      end

      it 'should call the bundled stemcell-copy if not found in the PATH' do
        allow(creator).to receive(:find_in_path).and_return(nil)
        result = double('result', :output => 'output')

        stemcell_copy = File.expand_path("../../../../bosh_aws_cpi/bin/stemcell-copy", __FILE__)
        cmd = "sudo -n #{stemcell_copy} /path/to/image /dev/volume 2>&1"
        expect(creator).to receive(:sh).with(cmd).and_return(result)

        creator.copy_root_image
      end
    end
  end
end
