require 'spec_helper'



describe Bosh::AwsCloud::AwsProvider do
  let(:options) do
    opts = mock_cloud_options['properties']
    opts
  end
  let(:logger) { Bosh::Clouds::Config.logger}
  let(:config) { Bosh::AwsCloud::Config.build(options.dup.freeze) }
  let(:params) do
    {
      credentials: config.aws.credentials,
      retry_limit: 8,
      logger: logger,
      log_level: :debug,
      region: 'us-east-1'
    }
  end
  let(:ec2_client) { instance_double(Aws::EC2::Client) }

  def configures_client_with_params
    expect(Aws::ElasticLoadBalancing::Client).to receive(:new).with(params)
    expect(Aws::ElasticLoadBalancingV2::Client).to receive(:new).with(params)
    expect(Aws::EC2::Client).to receive(:new).with(params).and_return(ec2_client)
    expect(Aws::EC2::Resource).to receive(:new).with(client: ec2_client)

    Bosh::AwsCloud::AwsProvider.new(config.aws, logger)
  end

  it { configures_client_with_params }

  context 'with endpoints set' do
    context 'with scheme' do
      before do
        options['aws'].delete('region')
        options['aws'].store('ec2_endpoint', 'http://the_endpoint.com')
        options['aws'].store('elb_endpoint', 'http://the_endpoint.com')
        params[:endpoint] = 'http://the_endpoint.com'
        params.delete(:region)
      end

      it { configures_client_with_params }
    end

    context 'without scheme' do
      before do
        options['aws'].delete('region')
        options['aws'].store('ec2_endpoint', 'the_endpoint.com')
        options['aws'].store('elb_endpoint', 'the_endpoint.com')
        params[:endpoint] = 'https://the_endpoint.com'
        params.delete(:region)
      end

      it { configures_client_with_params }
    end
  end

  context 'bosh ca cert file is set' do
    before do
      @original_bosh_ca_cert_file = ENV['BOSH_CA_CERT_FILE']
      ENV['BOSH_CA_CERT_FILE'] = '/some/path/file.pem'
      params[:ssl_ca_bundle] = '/some/path/file.pem'
    end

    after do
      if @original_bosh_ca_cert_file.nil?
        ENV.delete('BOSH_CA_CERT_FILE')
      else
        ENV['BOSH_CA_CERT_FILE'] = @original_bosh_ca_cert_file
      end
    end

    it { configures_client_with_params }
  end
end
