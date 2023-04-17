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
  let(:sts_client) { instance_double(Aws::STS::Client) }
  let(:assume_role_creds) { instance_double(Aws::AssumeRoleCredentials) }
  let(:env_prof_creds) { instance_double(Aws::InstanceProfileCredentials) }

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

      it 'claims registry is configured' do
        config = Bosh::AwsCloud::Config.build(options)
        expect(config.registry_configured?).to be_truthy
      end
    end

    context 'when registry is not defined in config' do
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

      context 'when stemcell api_version is higher than registry-less operation' do
        let(:stemcell_api_version) { 3 }
        it 'should allow usage of this version' do
          config = Bosh::AwsCloud::Config.build(options)
          expect(config.stemcell_api_version).to eq(3)
        end
      end
    end

    context 'when stemcell api_version is not specified' do
      it 'should default to 1' do
        config = Bosh::AwsCloud::Config.build(options)
        expect(config.stemcell_api_version).to eq(1)
      end
    end
  end

  context 'when the credentials source is static' do
    it 'should use the static Credentials' do
      config = Bosh::AwsCloud::Config.build(options)
      expect(config.aws.credentials).to be_a(Aws::Credentials)
    end

    context 'when role_arn is sent' do
      before do
        options['aws']['role_arn'] = 'arn:aws:iam::123456789012:role/role_name'
        options['aws']['session_token'] = 'session_token'
      end

      it 'should use the static AssumeRoleCredentials' do
        allow(Aws::STS::Client).to receive(:new).and_return(sts_client)
        allow(Aws::AssumeRoleCredentials).to receive(:new).and_return(assume_role_creds)
        config = Bosh::AwsCloud::Config.build(options)

        expect(config.aws.credentials).to be_a(assume_role_creds.class)
      end
    end
  end

  context 'when the credentials source is env_or_profile' do
    before do
      options['aws']['credentials_source'] = 'env_or_profile'
      options['aws']['access_key_id'] = nil
      options['aws']['secret_access_key'] = nil
    end

    it 'should use the EnvOrProfileCredentials' do
      allow(Aws::InstanceProfileCredentials).to receive(:new).and_return(env_prof_creds)
      config = Bosh::AwsCloud::Config.build(options)
      expect(config.aws.credentials).to be_a(env_prof_creds.class)
    end
  end

end
