require "common/common"
require "time"

module Bosh::AwsCloud
  class SpotManager
    TOTAL_WAIT_TIME_IN_SECONDS = 300
    RETRY_COUNT = 10

    def initialize(ec2)
      @ec2 = ec2
      @logger = Bosh::Clouds::Config.logger
    end

    def create(instance_params, spot_bid_price)
      @instance_params = instance_params
      spot_request_spec = {
        spot_price: "#{spot_bid_price}",
        instance_count: 1,
        launch_specification: instance_params
      }
      unless instance_params[:security_groups].nil?
        message = "Cannot use security group names when creating spot instances"
        @logger.error(message)
        raise Bosh::Clouds::VMCreationFailed.new(false), message
      end

      @logger.debug("Requesting spot instance with: #{spot_request_spec.inspect}")

      begin
        # the top-level ec2 class does not support spot instance methods
        @spot_instance_requests = @ec2.client.request_spot_instances(spot_request_spec)
        @logger.debug("Got spot instance requests: #{@spot_instance_requests.inspect}")
      rescue => e
        message = "Failed to get spot instance request: #{e.inspect}"
        @logger.error(message)
        raise Bosh::Clouds::VMCreationFailed.new(false), message
      end

      wait_for_spot_instance
    end

    private

    def wait_for_spot_instance
      instance = nil

      # Query the spot request state until it becomes "active".
      # This can result in the errors listed below; this is normally because AWS has
      # been slow to update its state so the correct response is to wait a bit and try again.
      errors = [Aws::EC2::Errors::InvalidSpotInstanceRequestIDNotFound]
      Bosh::Common.retryable(sleep: TOTAL_WAIT_TIME_IN_SECONDS/RETRY_COUNT, tries: RETRY_COUNT, on: errors) do |_, error|
        @logger.warn("Retrying after expected error: #{error}") if error

        status = spot_instance_request_status
        case status.state
          when 'failed'
            fail_spot_creation("VM spot instance creation failed: #{status.inspect}")
          when 'open'
            if status.status != nil && status.status.code == 'price-too-low'
              fail_spot_creation("Cannot create VM spot instance because bid price is too low: #{status.status.message}.")
            end
          when 'active'
            @logger.info("Spot request instances fulfilled: #{status.inspect}")
            instance = @ec2.instance(status.instance_id)
        end
      end

      instance
    rescue Bosh::Common::RetryCountExceeded
      fail_spot_creation("Timed out waiting for spot request #{@spot_instance_requests.inspect} to be fulfilled.")
    end

    def spot_instance_request_status
      @logger.debug('Checking state of spot instance requests...')
      response = @ec2.client.describe_spot_instance_requests(
        spot_instance_request_ids: spot_instance_request_ids
      )
      status = response.spot_instance_requests[0] # There is only ever 1
      @logger.debug("Spot instance request status: #{status.inspect}")
      status
    end

    def fail_spot_creation(message)
      @logger.warn(message)
      cancel_pending_spot_requests
      raise Bosh::Clouds::VMCreationFailed.new(false), message
    end

    def spot_instance_request_ids
      @spot_instance_requests.spot_instance_requests.map { |r| r.spot_instance_request_id }
    end

    def cancel_pending_spot_requests
      @logger.warn("Failed to create spot instance: #{@spot_instance_requests.inspect}. Cancelling request...")
      cancel_response = @ec2.client.cancel_spot_instance_requests(
        spot_instance_request_ids: spot_instance_request_ids
      )
      @logger.warn("Spot cancel request returned: #{cancel_response.inspect}")
    end
  end
end
