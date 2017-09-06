module Bosh::AwsCloud
  class AwsProvider
    # TODO(cdutra): remove me when cloud.rb is properly refactored, temporarily
    attr_reader :ec2_client, :ec2_resource

    def initialize(aws_config, logger)
      @logger = logger

      @elb_params = {
        region: aws_config.region,
        credentials: aws_config.credentials,
        logger: @logger,
      }
      elb_endpoint = aws_config.elb_endpoint
      if elb_endpoint
        if URI(@config.aws.elb_endpoint).scheme.nil?
          elb_endpoint = "https://#{elb_endpoint}"
        end
        @elb_params[:endpoint] = elb_endpoint
      end

      @elb_client = Aws::ElasticLoadBalancing::Client.new(@elb_params)
      @alb_client = Aws::ElasticLoadBalancingV2::Client.new(@elb_params)

      @aws_params = aws_params(aws_config, @logger)

      # AWS Ruby SDK is threadsafe but Ruby autoload isn't,
      # so we need to trigger eager autoload while constructing CPI
      Aws.eager_autoload!

      # In SDK v2 the default is more request driven, while the old 'model way' lives in Resource.
      # Therefore in most cases Aws::EC2::Resource would replace the client.
      @ec2_client = Aws::EC2::Client.new(@aws_params)
      @ec2_resource = Aws::EC2::Resource.new(client: @ec2_client)
    end

    def aws_accessible?
      # make an arbitrary HTTP request to ensure we can connect and creds are valid
      @ec2_resource.subnets.first
      true
    rescue Seahorse::Client::NetworkingError => e
      @logger.error("Failed to connect to AWS: #{e.inspect}\n#{e.backtrace.join("\n")}")
      err = "Unable to create a connection to AWS. Please check your provided settings: Region '#{@aws_params[:region] || 'Not provided'}', Endpoint '#{@aws_params[:endpoint] || 'Not provided'}'."
      cloud_error("#{err}\nIaaS Error: #{e.inspect}")
    rescue Net::OpenTimeout
      false
    end

    def alb_accessible?
      # make an arbitrary HTTP request to ensure we can connect and creds are valid
      @alb_client.describe_load_balancers(page_size: 1)
      true
    rescue Seahorse::Client::NetworkingError => e
      @logger.error("Failed to connect to AWS Application Load Balancer endpoint: #{e.inspect}\n#{e.backtrace.join("\n")}")
      err = "Unable to create a connection to AWS. Please check your provided settings: Region '#{@elb_params[:region] || 'Not provided'}', Endpoint '#{@elb_params[:endpoint] || 'Not provided'}'."
      cloud_error("#{err}\nIaaS Error: #{e.inspect}")
    rescue Net::OpenTimeout
      false
    end

    def elb_accessible?
      # make an arbitrary HTTP request to ensure we can connect and creds are valid
      @elb_client.describe_load_balancers(page_size: 1)
      true
    rescue Seahorse::Client::NetworkingError => e
      @logger.error("Failed to connect to AWS Elastic Load Balancer endpoint: #{e.inspect}\n#{e.backtrace.join("\n")}")
      err = "Unable to create a connection to AWS. Please check your provided settings: Region '#{@elb_params[:region] || 'Not provided'}', Endpoint '#{@elb_params[:endpoint] || 'Not provided'}'."
      cloud_error("#{err}\nIaaS Error: #{e.inspect}")
    rescue Net::OpenTimeout
      false
    end

    private

    def aws_params(aws_config, logger)
      aws_params = {
        retry_limit: aws_config.max_retries,
        logger: logger,
        log_level: :debug,
      }
      if aws_config.region
        aws_params[:region] = aws_config.region
      end
      if aws_config.ec2_endpoint
        endpoint = aws_config.ec2_endpoint
        if URI(aws_config.ec2_endpoint).scheme.nil?
          endpoint = "https://#{endpoint}"
        end
        aws_params[:endpoint] = endpoint
      end

      # TODO(cdutra): move this to a better place
      if ENV.has_key?('BOSH_CA_CERT_FILE')
        aws_params[:ssl_ca_bundle] = ENV['BOSH_CA_CERT_FILE']
      end

      aws_params
    end
  end
end