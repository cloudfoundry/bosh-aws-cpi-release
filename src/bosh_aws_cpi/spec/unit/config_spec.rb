require 'spec_helper'

describe Bosh::AwsCloud::Config do
  context 'validate registry' do
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
        'api_version'=> 1
      }
    end
    let(:validate_registry) { true }

    context 'when the registry should be a part of the required keys' do
      it 'should pass if the registry option is passed in' do
        expect{Bosh::AwsCloud::Config.validate(options, validate_registry)}.to_not raise_error
      end

      context 'when registry is not provided in options' do
        before do
          options.delete('registry')
        end

        it 'should raise error' do
          expect{ Bosh::AwsCloud::Config.validate(options, validate_registry) }.to raise_error(ArgumentError, /missing configuration parameters > registry:endpoint, registry:user, registry:password/)
        end
      end
    end

    context 'when registry should not be a part of the required keys' do
      let(:validate_registry) { false }

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
          expect{Bosh::AwsCloud::Config.validate(options, validate_registry)}.to_not raise_error
        end
      end

      context 'when registry option is specified' do
        it 'should not raise error' do
          expect{Bosh::AwsCloud::Config.validate(options, validate_registry)}.to_not raise_error
        end
      end
    end
  end
end
