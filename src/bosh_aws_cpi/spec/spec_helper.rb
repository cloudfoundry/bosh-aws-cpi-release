$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)

require 'tmpdir'
require 'bosh/cpi'
require 'cloud/aws'

MOCK_AWS_ACCESS_KEY_ID = 'foo'
MOCK_AWS_SECRET_ACCESS_KEY = 'bar'
PROJECT_RUBY_VERSION = ENV.fetch('PROJECT_RUBY_VERSION', File.read(File.join(File.dirname(__FILE__), '..', '.ruby-version'))).chomp
MOCK_CPI_API_VERSION = 2
def mock_cloud_options
  {
    'plugin' => 'aws',
    'properties' => {
      'aws' => {
        'access_key_id' => MOCK_AWS_ACCESS_KEY_ID,
        'secret_access_key' => MOCK_AWS_SECRET_ACCESS_KEY,
        'region' => 'us-east-1',
        'default_key_name' => 'sesame',
        'default_security_groups' => [],
        'max_retries' => 8,
        'source_dest_check' => false,
        'dualstack' => false
      },
      'registry' => {
        'endpoint' => 'localhost:42288',
        'user' => 'admin',
        'password' => 'admin'
      },
      'agent' => {
        'foo' => 'bar',
        'baz' => 'zaz'
      },
      'debug'=> {
        'cpi'=> {
          'api_version'=> MOCK_CPI_API_VERSION
        },
      },
    }
  }
end

def mock_cloud_properties_merge(override_options)
  mock_cloud_options_merge(override_options, mock_cloud_options['properties'])
end

def mock_cloud_options_merge(override_options, base_hash = mock_cloud_options)
  merged_options = {}
  override_options ||= {}
  base_hash ||= {}

  override_options.each do |key, value|
    if value.is_a? Hash
      merged_options[key] = mock_cloud_options_merge(override_options[key], base_hash[key])
    else
      merged_options[key] = value
    end
  end

  extra_keys = base_hash.keys - override_options.keys
  extra_keys.each { |key| merged_options[key] = base_hash[key] }

  merged_options
end

def mock_registry(endpoint = 'http://registry:3333')
  registry = instance_double(Bosh::Cpi::RegistryClient, :endpoint => endpoint)
  allow(Bosh::Cpi::RegistryClient).to receive(:new).and_return(registry)
  registry
end

def mock_cloud(options = nil)
  ec2 = mock_ec2
  allow(Aws::EC2::Resource).to receive(:new).and_return(ec2)

  yield ec2 if block_given?

  Bosh::AwsCloud::CloudV1.new(options || mock_cloud_options['properties'])
end

def mock_cloud_v3(options = nil)
  ec2 = mock_ec2
  allow(Aws::EC2::Resource).to receive(:new).and_return(ec2)

  yield ec2 if block_given?

  Bosh::AwsCloud::CloudV3.new(options || mock_cloud_options['properties'])
end

def mock_ec2
  client = instance_double(Aws::EC2::Client)
  allow(Aws::EC2::Client).to receive(:new).and_return(client)
  ec2 = double(Aws::EC2::Resource, client: client)

  yield ec2 if block_given?

  return ec2
end

def dynamic_network_spec
  {
      'type' => 'dynamic',
      'cloud_properties' => {
          'security_groups' => %w[default]
      }
  }
end

def vip_network_spec
  {
    'type' => 'vip',
    'ip' => '10.0.0.1',
    'cloud_properties' => {}
  }
end

def combined_network_spec
  {
    'network_a' => dynamic_network_spec,
    'network_b' => vip_network_spec
  }
end

def vm_type_spec
  {
    'key_name' => 'test_key',
    'availability_zone' => 'foobar-1a',
    'instance_type' => 'm3.zb'
  }
end

def asset(filename)
  File.expand_path(File.join(File.dirname(__FILE__), 'assets', filename))
end

def create_nic_mock(device_index, eni_id)
  nic = instance_double(Aws::EC2::Types::InstanceNetworkInterface)
  attachment = instance_double(Aws::EC2::Types::InstanceNetworkInterfaceAttachment)
  allow(attachment).to receive(:device_index).and_return(device_index)
  allow(nic).to receive(:attachment).and_return(attachment)
  allow(nic).to receive(:network_interface_id).and_return(eni_id) if device_index == 0
  nic
end

def mock_describe_instances(ec2_client, instance_id, nics)
  instance_data = instance_double(Aws::EC2::Types::Instance, network_interfaces: nics)
  reservation = instance_double(Aws::EC2::Types::Reservation, instances: [instance_data])
  response = instance_double(Aws::EC2::Types::DescribeInstancesResult, reservations: [reservation])
  expect(ec2_client).to receive(:describe_instances).with(instance_ids: [instance_id]).and_return(response)
end

def setup_vip_mocks(ec2_client, elastic_ip, describe_addresses_arguments, describe_addresses_response, allocation_id: 'allocation-id')
  expect(ec2_client).to receive(:describe_addresses)
    .with(describe_addresses_arguments).and_return(describe_addresses_response)
  expect(elastic_ip).to receive(:allocation_id).and_return(allocation_id)
end

RSpec.configure do |config|
  config.before do
    logger = Bosh::Cpi::Logger.new('/dev/null')
    allow(Bosh::Clouds::Config).to receive(:logger).and_return(logger)
    expect(RUBY_VERSION).to eq(PROJECT_RUBY_VERSION)
  end
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
end
