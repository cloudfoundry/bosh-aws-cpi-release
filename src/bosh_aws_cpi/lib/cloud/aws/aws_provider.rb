module Bosh::AwsCloud
  class AwsProvider
    include Helpers

    attr_reader :ec2_client, :ec2_resource, :alb_client, :elb_client

    def initialize(aws_config, logger)
      @aws_config = aws_config
      @logger = logger

      @elb_params = initialize_params(@aws_config.elb_endpoint)
      @elb_client = Aws::ElasticLoadBalancing::Client.new(@elb_params)
      @alb_client = Aws::ElasticLoadBalancingV2::Client.new(@elb_params)

      # In SDK v2 the default is more request driven, while the old 'model way' lives in Resource.
      # Therefore in most cases Aws::EC2::Resource would replace the client.
      @ec2_params = initialize_params(@aws_config.ec2_endpoint)
      @ec2_client = Aws::EC2::Client.new(@ec2_params)
      @ec2_resource = Aws::EC2::Resource.new(client: @ec2_client)
    end

    private

    def initialize_params(endpoint)
      params = {
        credentials: @aws_config.credentials,
        retry_limit: @aws_config.max_retries,
        logger: @logger,
        log_level: :debug,
        use_dualstack_endpoint: @aws_config.dualstack,
      }
      if @aws_config.region
        params[:region] = @aws_config.region
      end
      if endpoint
        if URI(endpoint).scheme.nil?
          endpoint = "https://#{endpoint}"
        end
        params[:endpoint] = endpoint
      end

      if ENV.has_key?('BOSH_CA_CERT_FILE')
        params[:ssl_ca_bundle] = ENV['BOSH_CA_CERT_FILE']
      end
      params
    end
  end
end
