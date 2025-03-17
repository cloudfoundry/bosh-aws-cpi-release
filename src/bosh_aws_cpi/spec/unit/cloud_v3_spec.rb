require 'spec_helper'

describe Bosh::AwsCloud::CloudV3 do
  subject(:cloud) { described_class.new(options) }

  let(:cloud_core) { instance_double(Bosh::AwsCloud::CloudCore) }
  let(:options) { mock_cloud_options['properties'] }
  let(:az_selector) { instance_double(Bosh::AwsCloud::AvailabilityZoneSelector) }

  before do
    allow(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(az_selector)
  end

  describe '#initialize' do

    context 'if stemcell api_version is 3' do
      let(:options) do
        mock_cloud_properties_merge(
          {
            'aws' => {
              'vm' => {
                'stemcell' => {
                  'api_version' => 3
                }
              }
            }
          }
        )
      end
      it 'should initialize cloud_core with agent_version 3' do
        allow(Bosh::AwsCloud::CloudCore).to receive(:new).and_return(cloud_core)
        expect(Bosh::AwsCloud::CloudCore).to receive(:new).with(anything, anything, anything, anything, 3).and_return(cloud_core)
        described_class.new(options)
      end

      context "no stemcell api version in options" do
        let(:options) do
          mock_cloud_properties_merge(
            {
              'aws' => {
                'vm' => {}
              }
            }
          )
        end
        it 'should initialize cloud_core with default stemcell api version of 1' do
          allow(Bosh::AwsCloud::CloudCore).to receive(:new).and_return(cloud_core)
          expect(Bosh::AwsCloud::CloudCore).to receive(:new).with(anything, anything, anything, anything, 1).and_return(cloud_core)
          described_class.new(options)
        end
      end
    end
  end

end
