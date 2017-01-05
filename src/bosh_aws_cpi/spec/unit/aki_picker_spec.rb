require "spec_helper"

describe Bosh::AwsCloud::AKIPicker do
  let(:resource) { instance_double(Aws::EC2::Resource) }
  let(:picker) { Bosh::AwsCloud::AKIPicker.new(resource) }
  let(:akis) {
    [
      double("image-1", :root_device_name => "/dev/sda1",
             :location => "pv-grub-hd00_1.03-x86_64.gz",
             :image_id => "aki-b4aa75dd"),
      double("image-2", :root_device_name => "/dev/sda1",
             :location => "pv-grub-hd00_1.02-x86_64.gz",
             :image_id => "aki-b4aa75d0")
    ]
  }

  before do
    allow(akis).to receive(:filter).and_return(akis)
    allow(resource).to receive(:images).and_return(akis)
  end

  it "should pick the AKI with the highest version" do
    expect(picker.pick("x86_64", "/dev/sda1")).to eq("aki-b4aa75dd")
  end

  it "should raise an error when it can't pick an AKI" do
    expect {
      picker.pick("foo", "bar")
    }.to raise_error Bosh::Clouds::CloudError, "unable to find AKI"
  end
end
