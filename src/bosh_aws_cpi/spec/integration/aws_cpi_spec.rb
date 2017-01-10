require 'spec_helper'
require 'json'
require 'tempfile'
require 'yaml'

describe "the aws_cpi executable" do

  before(:all) do
    @access_key_id     = ENV['BOSH_AWS_ACCESS_KEY_ID']       || raise('Missing BOSH_AWS_ACCESS_KEY_ID')
    @secret_access_key = ENV['BOSH_AWS_SECRET_ACCESS_KEY']   || raise('Missing BOSH_AWS_SECRET_ACCESS_KEY')
  end

  before(:each) do
    config_file.write(cloud_properties.to_yaml)
    config_file.close
  end

  let(:config_file) { Tempfile.new('cloud_properties.yml') }

  let(:cloud_properties) do
    {
      'cloud' => {
        'properties' => {
          'aws' => {
            'access_key_id' => @access_key_id,
            'secret_access_key' => @secret_access_key,
            'region' => 'us-east-1',
            'default_key_name' => 'default_key_name',
            'fast_path_delete' => 'yes',
            'max_retries' => 0
          },
          'registry' => {
            'endpoint' => 'fake',
            'user' => 'fake',
            'password' => 'fake'
          }
        }
      }
    }
  end

  context 'when given invalid credentials' do
    let(:cloud_properties) do
      {
        'cloud' => {
          'properties' => {
            'aws' => {
              'access_key_id' => 'fake-access-key',
              'secret_access_key' => 'fake-secret-key',
              'region' => 'us-east-1',
              'default_key_name' => 'default_key_name',
              'fast_path_delete' => 'yes',
              'max_retries' => 0
            },
              'registry' => {
              'endpoint' => 'fake',
              'user' => 'fake',
              'password' => 'fake'
            }
          }
        }
      }
    end

    it 'will not evaluate anything that causes an exception and will return the proper message to stdout' do
      result = run_cpi({'method'=>'ping', 'arguments'=>[], 'context'=>{'director_uuid' => 'abc123'}})

      expect(result.keys).to eq(%w(result error log))

      expect(result['result']).to be_nil

      expect(result['error']['message']).to match(/AWS was not able to validate the provided access credentials/)
      expect(result['error']['ok_to_retry']).to be(false)
      expect(result['error']['type']).to eq('Unknown')

      expect(result['log']).to include('backtrace')
    end
  end

  context 'when given an empty config file' do
    let(:cloud_properties) { {} }

    it 'will return an appropriate error message when passed an invalid config file' do
      result = run_cpi({'method'=>'ping', 'arguments'=>[], 'context'=>{'director_uuid' => 'abc123'}})

      expect(result.keys).to eq(%w(result error log))

      expect(result['result']).to be_nil

      expect(result['error']).to eq({
        'type' => 'Unknown',
        'message' => 'Could not find cloud properties in the configuration',
        'ok_to_retry' => false
      })

      expect(result['log']).to include('backtrace')
    end
  end

  context 'when given cpi config in the context' do
    let(:cloud_properties) {
      {
        'cloud' => {
          'properties' => {
            'aws' => {
            },
            'registry' => {
              'endpoint' => 'fake',
              'user' => 'fake',
              'password' => 'fake'
            }
          }
        }
      }
    }
    let(:context) {
      {
        'director_uuid' => 'abc123',
        'access_key_id' => @access_key_id,
        'secret_access_key' => @secret_access_key,
        'region' => 'us-east-1',
        'default_key_name' => 'default_key_name',
        'fast_path_delete' => 'yes',
        'max_retries' => 0
      }
    }
    it 'merges the context into the cloud_properties' do
      result = run_cpi({'method'=>'has_vm', 'arguments'=>['i-01f73de98ab33ad2f'], 'context'=> context})

      expect(result.keys).to eq(%w(result error log))

      expect(result['result']).to be_falsey
      expect(result['error']).to be_nil
    end
  end

  describe '#calculate_vm_cloud_properties' do
    it 'maps cloud agnostic VM properties to AWS-specific cloud_properties' do
      result = run_cpi({
        'method' => 'calculate_vm_cloud_properties',
        'arguments' => [{
          'ram' => 512,
          'cpu' => 1,
          'ephemeral_disk_size' => 2048,
        }],
        'context'=> {'director_uuid' => 'abc123'}
      })

      expect(result.keys).to eq(%w(result error log))

      expect(result['error']).to be_nil

      expect(result['result']).to eq({
        'instance_type' => 't2.nano',
        'ephemeral_disk' => {
          'size' => 2048,
        }
      })
    end

    context 'when required fields are missing' do
      it 'raises an error' do
        result = run_cpi({
          'method' => 'calculate_vm_cloud_properties',
          'arguments' => [{}],
          'context'=> {'director_uuid' => 'abc123'}
        })

        expect(result.keys).to eq(%w(result error log))

        expect(result['result']).to be_nil

        expect(result['error']['message']).to eq("Missing VM cloud properties: 'cpu', 'ram', 'ephemeral_disk_size'")
        expect(result['error']['ok_to_retry']).to be(false)
        expect(result['error']['type']).to eq('Unknown')

        expect(result['log']).to include('backtrace')
      end
    end
  end

  def run_cpi(input)
    command_file = Tempfile.new('command.json')
    command_file.write(input.to_json)
    command_file.close

    stdoutput = `bin/aws_cpi #{config_file.path} < #{command_file.path} 2> /dev/null`
    status = $?.exitstatus

    expect(status).to eq(0)
    JSON.parse(stdoutput)
  end
end
