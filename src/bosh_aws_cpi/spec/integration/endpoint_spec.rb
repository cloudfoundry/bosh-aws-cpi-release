require 'spec_helper'
require 'logger'
require 'cloud'
require 'open-uri'
require 'pry'

describe Bosh::AwsCloud::Cloud do
  before(:all) do
    @access_key_id     = ENV['BOSH_AWS_ACCESS_KEY_ID']       || raise("Missing BOSH_AWS_ACCESS_KEY_ID")
    @secret_access_key = ENV['BOSH_AWS_SECRET_ACCESS_KEY']   || raise("Missing BOSH_AWS_SECRET_ACCESS_KEY")
  end

  before { allow(Bosh::Clouds::Config).to receive_messages(logger: logger) }
  let(:logger) { Logger.new(STDERR) }

  describe 'specifying ec2 endpoint instead of region' do
    let(:cpi) do
      Bosh::AwsCloud::Cloud.new(
        'aws' => {
          'ec2_endpoint' => 'https://ec2.sa-east-1.amazonaws.com',
          'elb_endpoint' => 'https://elasticloadbalancing.sa-east-1.amazonaws.com',
          'region' => 'sa-east-1',
          'access_key_id' => @access_key_id,
          'default_key_name' => 'fake-key',
          'secret_access_key' => @secret_access_key,
          'max_retries' => 8
        },
        'registry' => {
          'endpoint' => 'fake',
          'user' => 'fake',
          'password' => 'fake'
        }
      )
    end

    it 'uses the given endpoint' do
      expect {
        cpi.has_vm?('i-010fd20eb24f606ab')
      }.to_not raise_error
    end
  end

  describe 'using a custom CA bundle' do
    let(:cpi) do
      Bosh::AwsCloud::Cloud.new(
        'aws' => {
          'region' => 'us-east-1',
          'default_key_name' => 'fake-key',
          'access_key_id' => @access_key_id,
          'secret_access_key' => @secret_access_key,
          'max_retries' => 8
        },
        'registry' => {
          'endpoint' => 'fake',
          'user' => 'fake',
          'password' => 'fake'
        }
      )
    end

    before(:all) do
      @original_cert_file = ENV['BOSH_CA_CERT_FILE']
    end

    after(:all) do
      if @original_cert_file.nil?
        ENV.delete('BOSH_CA_CERT_FILE')
      else
        ENV['BOSH_CA_CERT_FILE'] = @original_cert_file
      end
    end

    before(:each) { ENV.delete('BOSH_CA_CERT_FILE') }

    context 'when the certificate returned from the server contains a CA in the provided bundle' do
      it 'completes requests over SSL' do
        begin
          valid_bundle = File.open('valid-ca-bundle', 'w+') do |f|
            # Download the CA bundle that is included in the AWS SDK
            f << open('https://raw.githubusercontent.com/aws/aws-sdk-ruby/master/aws-sdk-core/ca-bundle.crt').read
          end

          ENV['BOSH_CA_CERT_FILE'] = valid_bundle.path

          expect {
            cpi.has_vm?('i-010fd20eb24f606ab')
          }.to_not raise_error
        ensure
          File.delete(valid_bundle.path)
        end

      end
    end

    context 'when the certificate returned from the server does not contain a CA in the provided bundle' do
      it 'raises an SSL verification error' do
        ENV['BOSH_CA_CERT_FILE'] = asset('invalid-cert.pem')

        expect {
          cpi.has_vm?('i-010fd20eb24f606ab')
        }.to raise_error(Seahorse::Client::NetworkingError)
      end
    end

    context 'when the endpoint is provided without a protocol' do
      let(:cpi) do
        Bosh::AwsCloud::Cloud.new(
          'aws' => {
            'ec2_endpoint' => 'ec2.sa-east-1.amazonaws.com',
            'elb_endpoint' => 'elasticloadbalancing.sa-east-1.amazonaws.com',
            'region' => 'sa-east-1',
            'access_key_id' => @access_key_id,
            'default_key_name' => 'fake-key',
            'secret_access_key' => @secret_access_key,
            'max_retries' => 8
          },
          'registry' => {
            'endpoint' => 'fake',
            'user' => 'fake',
            'password' => 'fake'
          }
        )
      end

      it 'auto-applies a protocol and uses the given endpoint' do
        expect {
          cpi.has_vm?('i-010fd20eb24f606ab')
        }.to_not raise_error
      end
    end
  end
end
