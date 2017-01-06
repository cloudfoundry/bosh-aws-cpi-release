require 'spec_helper'

describe Bosh::AwsCloud::Stemcell do
  let(:resource) { instance_double(Aws::EC2::Resource) }
  describe ".find" do
    it "should return an AMI if given an id for an existing one" do
      fake_aws_ami = double("image", exists?: true)
      allow(resource).to receive(:image).with('ami-exists').and_return(fake_aws_ami)
      expect(described_class.find(resource, "ami-exists").ami).to eq(fake_aws_ami)
    end

    it "should raise an error if no AMI exists with the given id" do
      fake_aws_ami = double("image", exists?: false)
      allow(resource).to receive(:image).with('ami-doesntexist').and_return(fake_aws_ami)
      expect {
        described_class.find(resource, "ami-doesntexist")
      }.to raise_error Bosh::Clouds::CloudError, "could not find AMI 'ami-doesntexist'"
    end
  end

  describe "#image_id" do
    let(:fake_aws_ami) { double("image", id: "my-id") }

    it "returns the id of the ami object" do
      stemcell = described_class.new(resource, fake_aws_ami)
      expect(stemcell.image_id).to eq('my-id')
    end
  end

  describe "#delete" do
    let(:snapshot_id) { 'snap-xxxxxxxx' }
    let(:ami_id) { 'ami-xxxxxxxx' }

    let(:fake_snapshot) { instance_double(Aws::EC2::Snapshot) }
    let(:block_devices) do
      [
        instance_double(Aws::EC2::Types::BlockDeviceMapping, ebs: double('ebs',
          snapshot_id: snapshot_id,
        ))
      ]
    end
    let(:fake_aws_ami) do
      instance_double(Aws::EC2::Image, exists?: true, id: ami_id)
    end

    before(:each) do
      allow(fake_aws_ami).to receive(:block_device_mappings).and_return(block_devices)

      allow(resource).to receive(:image).with(ami_id).and_return(fake_aws_ami)
      allow(resource).to receive(:snapshot).with(snapshot_id).and_return(fake_snapshot)
    end

    context "with real stemcell" do
      it "should deregister the ami" do
        stemcell = described_class.new(resource, fake_aws_ami)

        expect(fake_aws_ami).to receive(:deregister).ordered
        allow(Bosh::AwsCloud::ResourceWait).to receive(:for_image).with(image: fake_aws_ami, state: 'deleted')
        expect(fake_snapshot).to receive(:delete).ordered

        stemcell.delete
      end
    end

    context "with light stemcell" do
      it "should raise an error" do
        stemcell = described_class.new(resource, fake_aws_ami)

        expect(fake_aws_ami).to receive(:deregister).and_raise(Aws::EC2::Errors::AuthFailure.new(nil, 'auth-failure'))
        expect(Bosh::AwsCloud::ResourceWait).not_to receive(:for_image)

        expect {stemcell.delete}.to raise_error(Aws::EC2::Errors::AuthFailure)
      end
    end

    context 'when the AMI is not found after deletion' do
      it 'should not propagate a Aws::Core::Resource::NotFound error' do
        stemcell = described_class.new(resource, fake_aws_ami)

        expect(fake_aws_ami).to receive(:deregister).ordered

        allow(Bosh::AwsCloud::ResourceWait).to receive(:for_image)
          .with(image: fake_aws_ami, state: 'deleted')
          .and_return(Aws::EC2::Errors::ResourceNotFound.new(nil, 'not-found'))

        expect(fake_snapshot).to receive(:delete).ordered

        stemcell.delete
      end
    end
  end
end
