require 'spec_helper'

describe Bosh::AwsCloud::Cloud, '#set_disk_metadata' do
  let(:volume) { double(Aws::EC2::Volume, id: 'vol-xxxxxxxx') }
  let(:metadata) { { 'deployment' => 'deployment-x', 'instance_id' => 'instance-x' } }

  before :each do
    @cloud = mock_cloud do |ec2|
      expect(ec2).to receive(:volume).with('vol-xxxxxxxx').and_return(volume)
    end
  end

  it 'should tag with given metadata' do
    allow(Bosh::AwsCloud::TagManager).to receive(:tags)

    @cloud.set_disk_metadata('vol-xxxxxxxx', metadata)

    expect(Bosh::AwsCloud::TagManager).to have_received(:tags).with(volume, metadata)
  end

  context 'when tag limit exceeded' do
    it 'should log the error' do
      allow(Bosh::AwsCloud::TagManager).to receive(:tags).and_raise(Aws::EC2::Errors::TagLimitExceeded.new(nil, 'some message'))
      allow(Bosh::Clouds::Config.logger).to receive(:error)

      @cloud.set_disk_metadata('vol-xxxxxxxx', metadata)

      expect(Bosh::Clouds::Config.logger).to have_received(:error).with("could not tag vol-xxxxxxxx: some message")
    end
  end
end
