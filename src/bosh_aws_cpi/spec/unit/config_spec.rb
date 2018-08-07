require 'spec_helper'

describe Bosh::AwsCloud::Config do
  let(:cpi_api_version) { 2 }
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
      'registry'=> {
        'endpoint'=> 'url',
        'user'=> 'registry',
        'password'=> '8fttyhp6e5w78bn3dpao'
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
          'api_version'=> cpi_api_version
        },
      },
    }
  end

  describe 'registry validation' do
    context 'when api_version is specified in options' do
      let(:cpi_api_version) { 42 }
      let(:registry_required) { false }

      it 'should use the specified api_version' do
        config = Bosh::AwsCloud::Config.build(options, registry_required)
        expect(config.api_version).to eq(cpi_api_version)
      end
    end

    context 'when the registry should be a part of the required keys' do
      let(:registry_required) { true }

      it 'should pass if the registry option is passed in' do
        expect{Bosh::AwsCloud::Config.validate(options, registry_required)}.to_not raise_error
      end

      context 'when registry is not provided in options' do
        before do
          options.delete('registry')
        end

        it 'should raise error' do
          expect{ Bosh::AwsCloud::Config.validate(options, registry_required) }.to raise_error(ArgumentError, /missing configuration parameters > registry:endpoint, registry:user, registry:password/)
        end
      end
    end

    context 'when registry should not be a part of the required keys' do
      let(:registry_required) { false }

      context 'when registry option is not specified' do
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
            'api_version'=> 1
          }
        end

        it 'should pass' do
          expect{Bosh::AwsCloud::Config.validate(options, registry_required)}.to_not raise_error
        end
      end

      context 'when registry option is specified' do
        it 'should not raise error' do
          expect{Bosh::AwsCloud::Config.validate(options, registry_required)}.to_not raise_error
        end
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
        config = Bosh::AwsCloud::Config.build(options, registry_required)
        expect(config.stemcell_api_version).to eq(stemcell_api_version)
      end
    end

    context 'when stemcell api_version is not specified' do
      it 'should default to 1' do
        config = Bosh::AwsCloud::Config.build(options, registry_required)
        expect(config.stemcell_api_version).to eq(1)
      end
    end
  end
end
