module Bosh::AwsCloud
  class AwsConfig
    attr_reader :max_retries, :credentials_source, :region, :ec2_endpoint, :elb_endpoint, :stemcell
    attr_reader :access_key_id, :secret_access_key

    def initialize(aws_config_hash)
      @config = aws_config_hash

      @max_retries = @config['max_retries']
      @credentials_source =  @config['credentials_source'] || 'static'
      @region = @config['region']
      @ec2_endpoint = @config['ec2_endpoint']
      @elb_endpoint = @config['elb_endpoint']

      @access_key_id = @config['access_key_id']
      @secret_access_key = @config['secret_access_key']

      @stemcell = @config['stemcell'] || {}
      @fast_path_delete = @config['fast_path_delete'] || false
    end

    def to_h
      @config
    end

    def fast_path_delete?
      @fast_path_delete
    end
  end

  class RegistryConfig
    attr_reader :endpoint, :user, :password

    def initialize(registry_config_hash)
      @config = registry_config_hash

      @endpoint = @config['endpoint']
      @user =  @config['user']
      @password = @config['password']
    end
  end

  class AgentConfig
    def initialize(agent_config_hash)
      @config = agent_config_hash
    end

    def to_h
      @config
    end
  end

  class Config
    attr_reader :aws, :registry, :agent

    def self.build(config_hash)
      new(config_hash).tap(&:validate)
    end

    def validate
      validate_options
      validate_credentials_source
    end

    private

    def initialize(config_hash)
      @config = config_hash
      @aws = AwsConfig.new(config_hash['aws'] || {})
      @registry = RegistryConfig.new(config_hash['registry'] || {})
      @agent = AgentConfig.new(config_hash['agent'] || {})
    end


    ##
    # Checks if options passed to CPI are valid and can actually
    # be used to create all required data structures etc.
    #
    def validate_options
      missing_keys = []

      REQUIRED_KEYS.each_pair do |key, values|
        values.each do |value|
          if (!@config.has_key?(key) || !@config[key].has_key?(value))
            missing_keys << "#{key}:#{value}"
          end
        end
      end

      raise ArgumentError, "missing configuration parameters > #{missing_keys.join(', ')}" unless missing_keys.empty?

      if !@config['aws'].has_key?('region') && ! (@config['aws'].has_key?('ec2_endpoint') && @config['aws'].has_key?('elb_endpoint'))
        raise ArgumentError, 'missing configuration parameters > aws:region, or aws:ec2_endpoint and aws:elb_endpoint'
      end
    end

    ##
    # Checks AWS credentials settings to see if the CPI
    # will be able to authenticate to AWS.
    #
    def validate_credentials_source
      credentials_source = @config['aws']['credentials_source'] || 'static'

      if credentials_source != 'env_or_profile' && credentials_source != 'static'
        raise ArgumentError, "Unknown credentials_source #{credentials_source}"
      end

      if credentials_source == 'static'
        if @config['aws']['access_key_id'].nil? || @config['aws']['secret_access_key'].nil?
          raise ArgumentError, 'Must use access_key_id and secret_access_key with static credentials_source'
        end
      end

      if credentials_source == 'env_or_profile'
        if !@config['aws']['access_key_id'].nil? || !@config['aws']['secret_access_key'].nil?
          raise ArgumentError, "Can't use access_key_id and secret_access_key with env_or_profile credentials_source"
        end
      end
    end

    REQUIRED_KEYS = {
      'aws' => ['default_key_name', 'max_retries'],
      'registry' => ['endpoint', 'user', 'password'],
    }.freeze

  end
end
