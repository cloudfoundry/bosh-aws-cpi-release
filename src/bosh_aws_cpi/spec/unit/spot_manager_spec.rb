require 'spec_helper'

describe Bosh::AwsCloud::SpotManager do
  let(:spot_manager) { described_class.new(ec2) }
  let(:ec2) { instance_double(Aws::EC2::Resource) }
  let(:aws_client) { instance_double(Aws::EC2::Client) }
  let(:fake_instance_params) { { fake: 'params' } }
  let(:request_spot_instances_result) {
    instance_double(Aws::EC2::Types::RequestSpotInstancesResult, spot_instance_requests: spot_instance_requests)
  }
  let(:spot_instance_requests) {
    [ instance_double(Aws::EC2::Types::SpotInstanceRequest, spot_instance_request_id: 'sir-12345c') ]
  }
  let(:spot_instance_status) { instance_double(Aws::EC2::Types::SpotInstanceStatus) }
  let(:describe_spot_instance_requests_result) {
    instance_double(Aws::EC2::Types::DescribeSpotInstanceRequestsResult, spot_instance_requests: spot_instance_requests)
  }
  let(:instance) { double(Aws::EC2::Instance, id: 'i-12345678') }

  before do
    allow(ec2).to receive(:client).and_return(aws_client)
  end

  it 'fails to create the spot instance if instance_params[:security_group] is set' do
    invalid_instance_params = { fake: 'params', security_groups: ['sg-name'] }
    expect(Bosh::Clouds::Config.logger).to receive(:error).with(/Cannot use security group names when creating spot instances/)
    expect{
      spot_manager.create(invalid_instance_params, 0.24)
    }.to raise_error(Bosh::Clouds::VMCreationFailed, /Cannot use security group names when creating spot instances/) { |error|
      expect(error.ok_to_retry).to eq false
    }
  end

  it 'should fail VM creation and log an error when there is a CPI error' do
    aws_error = Aws::EC2::Errors::InvalidParameterValue.new(nil, %q{price "0.3" exceeds your maximum Spot price limit of "0.24"})
    expect(aws_client).to receive(:request_spot_instances).and_raise(aws_error)

    expect(Bosh::Clouds::Config.logger).to receive(:error).with(/Failed to get spot instance request/)

    expect {
      spot_manager.create(fake_instance_params, 0.24)
    }.to raise_error(Bosh::Clouds::VMCreationFailed) { |error|
      expect(error.ok_to_retry).to eq false
      expect(error.message).to include("Failed to get spot instance request")
      expect(error.message).to include(aws_error.inspect)
    }
  end

  describe 'when correct parameters are passed to `spot_manager.create`' do
    before do
      allow(ec2).to receive(:instance).with('i-12345678').and_return(instance)

      expect(aws_client).to receive(:request_spot_instances).with({
        spot_price: '0.24',
        instance_count: 1,
        launch_specification: { fake: 'params' }
      }).and_return(request_spot_instances_result)

      # Override total_spot_instance_request_wait_time to be "unit test" speed
      stub_const('Bosh::AwsCloud::SpotManager::TOTAL_WAIT_TIME_IN_SECONDS', 0.1)
    end

    context 'and state is `open`' do
      before do
        allow(spot_instance_requests[0]).to receive(:state).and_return('open')
        allow(spot_instance_requests[0]).to receive(:status).and_return(spot_instance_status)
      end

      it 'should fail to return an instance when starting a spot instance times out' do
        allow(spot_instance_status).to receive(:code).and_return('foo')

        expect(aws_client).to receive(:describe_spot_instance_requests).
          exactly(Bosh::AwsCloud::SpotManager::RETRY_COUNT).times.with({ spot_instance_request_ids: ['sir-12345c'] }).
          and_return(describe_spot_instance_requests_result)

        # When erroring, should cancel any pending spot requests
        expect(aws_client).to receive(:cancel_spot_instance_requests)

        expect {
          spot_manager.create(fake_instance_params, 0.24)
        }.to raise_error(Bosh::Clouds::VMCreationFailed) { |error|
          expect(error.ok_to_retry).to eq false
        }
      end

      it 'should immediately fail to return an instance when spot bid price is too low' do
        allow(spot_instance_status).to receive(:code).and_return('price-too-low')
        allow(spot_instance_status).to receive(:message).and_return('bid price too low')

        expect(aws_client).to receive(:describe_spot_instance_requests).
          exactly(1).times.
          with({ spot_instance_request_ids: ['sir-12345c'] }).
          and_return(describe_spot_instance_requests_result)

        # When erroring, should cancel any pending spot requests
        expect(aws_client).to receive(:cancel_spot_instance_requests)

        expect {
          spot_manager.create(fake_instance_params, 0.24)
        }.to raise_error(Bosh::Clouds::VMCreationFailed) { |error|
          expect(error.ok_to_retry).to eq false
        }
      end
    end

    context 'and when state is `active`' do
      before do
        expect(spot_instance_requests[0]).to receive(:state).and_return('active')
        expect(spot_instance_requests[0]).to receive(:instance_id).and_return('i-12345678')
      end

      it 'request sends AWS request for spot instance' do
        expect(aws_client).to receive(:describe_spot_instance_requests).and_return(describe_spot_instance_requests_result)

        expect(spot_manager.create(fake_instance_params, 0.24)).to be(instance)
      end

      it 'should retry checking spot instance request state when Aws::EC2::Errors::InvalidSpotInstanceRequestID::NotFound raised' do
        #Simulate first receiving an error when asking for spot request state
        expect(aws_client).to receive(:describe_spot_instance_requests).with({ spot_instance_request_ids: ['sir-12345c'] }).
          and_raise(Aws::EC2::Errors::InvalidSpotInstanceRequestIDNotFound.new(nil, 'not-found'))
        expect(aws_client).to receive(:describe_spot_instance_requests).with({ spot_instance_request_ids: ['sir-12345c'] }).
          and_return(describe_spot_instance_requests_result)

        #Shouldn't cancel spot request when things succeed
        expect(aws_client).to_not receive(:cancel_spot_instance_requests)

        expect {
          spot_manager.create(fake_instance_params, 0.24)
        }.to_not raise_error
      end
    end

    it 'should fail VM creation (no retries) when spot request status == failed' do
      expect(spot_instance_requests[0]).to receive(:state).and_return('failed')

      expect(aws_client).to receive(:describe_spot_instance_requests).
        with({ spot_instance_request_ids: ['sir-12345c'] }).
        and_return(describe_spot_instance_requests_result)

      # When erroring, should cancel any pending spot requests
      expect(aws_client).to receive(:cancel_spot_instance_requests)

      expect {
        spot_manager.create(fake_instance_params, 0.24)
      }.to raise_error(Bosh::Clouds::VMCreationFailed) { |error|
        expect(error.ok_to_retry).to eq false
      }
    end
  end
end
