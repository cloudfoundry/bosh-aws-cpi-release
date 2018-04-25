require 'spec_helper'

describe Bosh::Clouds::Config do
  it 'should configure a logger' do
    expect(Bosh::Clouds::Config.logger).to be_kind_of(Logger)
  end

  it 'should configure a uuid' do
    expect(Bosh::Clouds::Config.uuid).to be_kind_of(String)
  end

  it 'should not have a db configured' do
    expect(Bosh::Clouds::Config.db).to be_nil
  end

  it 'should configure a task_checkpoint' do
    expect(Bosh::Clouds::Config.respond_to?(:task_checkpoint)).to be(true)
  end

  context 'validate registry' do
    let(:options) do
      {
        'aws'=> {
          'max_retries'=> 8,
          'default_security_groups'=> [
            'bosh'
          ],
          'default_key_name'=> 'smurf',
          'region'=> 'us-east-1',
          'kms_key_arn'=> null,
          'encrypted'=> false,
          'credentials_source'=> 'static',
          'access_key_id'=> 'xxxxxxx',
          'secret_access_key'=> 'xxxxxxx',
          'session_token'=> null,
          'default_iam_instance_profile'=> null
        },
        'registry'=> {
          'endpoint'=> 'http://registry:password@10.0.1.6:25777',
          'user'=> 'registry',
          'password'=> 'password'
        },
        'agent'=> {
          'ntp'=> [
            'time1.google.com',
            'time2.google.com',
            'time3.google.com',
          ],
          'blobstore'=> {
            'provider'=> 'dav',
            'options'=> {
              'endpoint'=> 'http://10.0.1.6:25250',
              'user'=> 'agent',
              'password'=> 'password'
            }
          },
          'mbus'=> 'nats://nats:password@10.0.1.6:4222'
        },
        'api_version'=> 1
      }
    end
    let(:validate_registry) { true }

    before do
      @config = Config.build(options, validate_registry)
    end

    context 'when the registry should be a part of the required keys' do
      it 'should pass if the registry option is passed in' do
        expect(@config.validate).to_not raise_error
      end

      it 'should not pass if the registry option is passed in' do
      end
    end

    context 'when registry should not be a part of the required keys' do
      let(:validate_registry) { false }

      it 'should pass if registry option is not passed in'
      it 'should fail if the registry option is passed in'
    end
  end
end
