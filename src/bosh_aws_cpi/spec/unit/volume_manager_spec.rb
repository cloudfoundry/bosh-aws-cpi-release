require 'spec_helper'

module Bosh::AwsCloud

  describe :VolumeManager do
    let(:volume_manager) { VolumeManager.new(logger, aws_provider) }

    let(:logger) { double }
    let(:aws_provider) { Bosh::AwsCloud::AwsProvider.new(config.aws, logger) }

    let(:config) { Bosh::AwsCloud::Config.build(cloud_options.dup.freeze) }

    let(:cloud_options) { mock_cloud_options['properties'] }

    let(:ec2_resource) { instance_double(Aws::EC2::Resource) }
    let(:ec2_client) { instance_double(Aws::EC2::Client) }

    before do
      allow(aws_provider).to receive(:ec2_resource).and_return(ec2_resource)
      allow(aws_provider).to receive(:ec2_client).and_return(ec2_client)
    end

    describe '#extend_ebs_volume' do
      let(:mock_volume) { double }
      let(:mock_resp) { double }
      let(:new_size) { 2048000 }

      before do
        allow(mock_volume).to receive(:id).and_return(1234)
        allow(ec2_client)
          .to receive(:modify_volume)
          .with(volume_id: 1234, size: new_size)
          .and_return(mock_resp)
        allow(mock_resp).to receive(:volume_modification)
        allow(SdkHelpers::VolumeModification).to receive(:new)
        allow(logger).to receive(:info)
        allow(ResourceWait).to receive(:for_volume_modification)
      end

      it 'should modify the volume with new size' do
        volume_manager.extend_ebs_volume(mock_volume, new_size)

        expect(ec2_client).to have_received(:modify_volume).with(volume_id: 1234, size: new_size)
        expect(SdkHelpers::VolumeModification).to have_received(:new)
        expect(logger).to have_received(:info)

        expect(ResourceWait).to have_received(:for_volume_modification)
      end
    end
  end
end