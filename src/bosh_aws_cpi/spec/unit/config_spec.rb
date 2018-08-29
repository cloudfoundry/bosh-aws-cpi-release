require 'spec_helper'

describe Bosh::AwsCloud::Config do
  let(:debug_api_version) { nil }
  let(:options) do
    {
      'aws'=> {
        'max_retries'=> 8,
        'default_security_groups'=> [
          'bosh'
        ],
        'default_key_name'=> 'bosh-bay-2',
        'region'=> 'us-east-1',
        'kms_key_arn'=> nil,
        'encrypted'=> false,
        'credentials_source'=> 'static',
        'access_key_id'=> 'key_id',
        'secret_access_key'=> 'secret',
        'session_token'=> nil,
        'default_iam_instance_profile'=> nil
      },
      'agent'=> {
        'ntp'=> [
          'time1.google.com',
          'time2.google.com',
          'time3.google.com',
          'time4.google.com'
        ],
        'blobstore'=> {
          'provider'=> 'dav',
          'options'=> {
            'endpoint'=> 'url',
            'user'=> 'agent',
            'password'=> 'password'
          }
        },
        'mbus'=> 'url'
      },
      'debug'=> {
        'cpi'=> {
          'api_version'=> debug_api_version
        },
      },
    }
  end

  describe 'registry validation' do
    context 'when `debug.cpi.api_version` is specified in options' do
      let(:debug_api_version) { 1 }

      it 'should use the specified api_version' do
        config = Bosh::AwsCloud::Config.build(options)
        expect(config.supported_api_version).to eq(debug_api_version)
      end

      context 'when specified version is greater then MAX_SUPPORTED_API_VERSION' do
        let(:debug_api_version) { 42 }

        it 'should use MAX_SUPPORTED_API_VERSION' do
          config = Bosh::AwsCloud::Config.build(options)
          expect(config.supported_api_version).to eq(Bosh::AwsCloud::Config::MAX_SUPPORTED_API_VERSION)
        end
      end
    end

    context 'when the registry is defined in the config' do
      before(:each) do
        options['registry'] = {
          'endpoint'=> 'url',
          'user'=> 'registry',
          'password'=> '8fttyhp6e5w78bn3dpao'
        }
      end

      it 'should pass if the registry option is passed in' do
        expect{Bosh::AwsCloud::Config.validate(options)}.to_not raise_error
      end

      it 'claims registry is configured' do
        config = Bosh::AwsCloud::Config.build(options)
        expect(config.registry_configured?).to be_truthy
      end

      it 'should fail validation if user is missing' do
        options['registry'].delete('user')
        expect{Bosh::AwsCloud::Config.validate(options)}.to raise_error(ArgumentError, "missing configuration parameters > registry:user")
      end

      it 'should fail validation if endpoint is missing' do
        options['registry'].delete('endpoint')
        expect{Bosh::AwsCloud::Config.validate(options)}.to raise_error(ArgumentError, "missing configuration parameters > registry:endpoint")
      end

      it 'should fail validation if password is missing' do
        options['registry'].delete('password')
        expect{Bosh::AwsCloud::Config.validate(options)}.to raise_error(ArgumentError, "missing configuration parameters > registry:password")
      end
    end

    context 'when registry is not defined in config' do
      it 'should not raise an error during validate' do
        expect{Bosh::AwsCloud::Config.validate(options)}.to_not raise_error
      end

      it 'should claim registry is not configured' do
        config = Bosh::AwsCloud::Config.build(options)
        expect(config.registry_configured?).to be_falsey
      end
    end
  end

  context 'stemcell api version' do
    let(:registry_required) { false }
    let(:stemcell_api_version) { 2 }

    context 'when stemcell api_version is specified' do
      before do
        options['aws'].merge!({'vm' => {'stemcell' => {'api_version' => stemcell_api_version}}})
      end

      it 'should be parsed' do
        config = Bosh::AwsCloud::Config.build(options)
        expect(config.stemcell_api_version).to eq(stemcell_api_version)
      end
    end

    context 'when stemcell api_version is not specified' do
      it 'should default to 1' do
        config = Bosh::AwsCloud::Config.build(options)
        expect(config.stemcell_api_version).to eq(1)
      end
    end
  end
end
