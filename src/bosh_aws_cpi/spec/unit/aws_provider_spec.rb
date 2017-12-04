require 'spec_helper'

describe Bosh::AwsCloud::AwsProvider do

  let(:options) do
    opts = mock_cloud_options['properties']
    opts
  end
  let(:logger) { Bosh::Clouds::Config.logger}
  let(:config) { Bosh::AwsCloud::Config.build(options.dup.freeze) }
  let(:provider) { Bosh::AwsCloud::AwsProvider.new(config.aws, logger) }

  it 'should configure elb_params' do
    params = provider.elb_params
    expect(params[:region]).to eq('us-east-1')
    expect(params[:endpoint]).to eq(nil)
    expect(params[:ssl_ca_bundle]).to eq(nil)
    expect(params[:retry_limit]).to eq(8)
    expect(params[:log_level]).to eq(:debug)
  end

  it 'should configure ec2_params' do
    params = provider.ec2_params
    expect(params[:region]).to eq('us-east-1')
    expect(params[:endpoint]).to eq(nil)
    expect(params[:ssl_ca_bundle]).to eq(nil)
    expect(params[:retry_limit]).to eq(8)
    expect(params[:logger]).to be_truthy
    expect(params[:log_level]).to eq(:debug)
  end

  context 'no region is set' do
    let(:options) do
      opts = mock_cloud_options['properties']
      opts['aws'].delete('region')
      opts['aws'].store("ec2_endpoint", "http://the_ec2_endpoint.com")
      opts['aws'].store("elb_endpoint", "http://the_elb_endpoint.com")
      opts
    end

    it 'should configure elb_params' do
      params = provider.elb_params
      expect(params[:region]).to eq(nil)
    end

    it 'should configure ec2_params' do
      params = provider.ec2_params
      expect(params[:region]).to eq(nil)
    end
  end

  context 'endpoints are set with protocol' do
    let(:options) do
      opts = mock_cloud_options['properties']
      opts['aws'].store("ec2_endpoint", "http://the_ec2_endpoint.com")
      opts['aws'].store("elb_endpoint", "http://the_elb_endpoint.com")
      opts
    end

    it 'should configure elb_params' do
      params = provider.elb_params
      expect(params[:endpoint]).to eq("http://the_elb_endpoint.com")
    end

    it 'should configure ec2_params' do
      params = provider.ec2_params
      expect(params[:endpoint]).to eq("http://the_ec2_endpoint.com")
    end
  end

  context 'endpoints have no protocol' do
    let(:options) do
      opts = mock_cloud_options['properties']
      opts['aws'].store("ec2_endpoint", "the_ec2_endpoint.com")
      opts['aws'].store("elb_endpoint", "the_elb_endpoint.com")
      opts
    end

    it 'should configure elb_params' do
      params = provider.elb_params
      expect(params[:endpoint]).to eq("https://the_elb_endpoint.com")
    end

    it 'should configure ec2_params' do
      params = provider.ec2_params
      expect(params[:endpoint]).to eq("https://the_ec2_endpoint.com")
    end
  end

  context 'bosh ca cert file is set' do
    before do
      ENV['BOSH_CA_CERT_FILE'] = "/some/path/file.pem"
    end

    after do
      ENV.delete('BOSH_CA_CERT_FILE')
    end
    it 'should configure elb_params' do
      params = provider.elb_params
      expect(params[:ssl_ca_bundle]).to eq('/some/path/file.pem')
    end

    it 'should configure ec2_params' do
      params = provider.ec2_params
      expect(params[:ssl_ca_bundle]).to eq('/some/path/file.pem')
    end
  end
end
