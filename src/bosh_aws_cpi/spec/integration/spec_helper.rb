require 'spec_helper'
require 'integration/helpers/ec2_helper'


def validate_minimum_permissions(logger)
  if @permissions_auditor_key_id && @permissions_auditor_secret_key
    sts_client = Aws::STS::Client.new(
      region: @region,
      access_key_id: @access_key_id,
      secret_access_key: @secret_access_key,
      session_token: @session_token
    )
    integration_test_user_arn = sts_client.get_caller_identity.arn
    raise 'Cannot get user ARN' if integration_test_user_arn.nil?

    iam_client = Aws::IAM::Client.new(
      region: @region,
      access_key_id: @permissions_auditor_key_id,
      secret_access_key: @permissions_auditor_secret_key,
      session_token: @session_token,
      logger: logger
    )

    user_details = iam_client.get_account_authorization_details(filter: ['User']).user_detail_list.find { |user| user.arn == integration_test_user_arn }
    raise "Cannot find user with ARN: #{integration_test_user_arn}" if user_details.nil?

    policy_documents = []
    policy_documents += user_details.attached_managed_policies.map do |p|
      version_id = iam_client.get_policy(policy_arn: p.policy_arn).policy.default_version_id
      iam_client.get_policy_version(policy_arn: p.policy_arn, version_id: version_id).policy_version.document
    end
    policy_documents += user_details.user_policy_list.map(&:policy_document)

    actions = policy_documents.map do |document|
      JSON.parse(URI.unescape(document))['Statement'].map do |s|
        s['Action']
      end.flatten
    end.flatten.uniq

    minimum_action = JSON.parse(File.read File.join(ENV['RELEASE_DIR'], 'docs/iam-policy.json'))['Statement'].map do |s|
      s['Action']
    end.flatten.uniq

    expect(actions).to match_array(minimum_action)
  end
end

RSpec.configure do |rspec_config|
  include IntegrationHelpers

  rspec_config.before(:all) do
    @access_key_id                  = ENV.fetch('BOSH_AWS_ACCESS_KEY_ID')
    @secret_access_key              = ENV.fetch('BOSH_AWS_SECRET_ACCESS_KEY')
    @session_token                  = ENV.fetch('BOSH_AWS_SESSION_TOKEN', nil)
    @subnet_id                      = ENV.fetch('BOSH_AWS_SUBNET_ID')
    @subnet_zone                    = ENV.fetch('BOSH_AWS_SUBNET_ZONE')
    @kms_key_arn                    = ENV.fetch('BOSH_AWS_KMS_KEY_ARN')
    @region                         = ENV.fetch('BOSH_AWS_REGION', 'us-west-1')
    @default_key_name               = ENV.fetch('BOSH_AWS_DEFAULT_KEY_NAME', 'bosh')
    @ami                            = ENV.fetch('BOSH_AWS_IMAGE_ID', 'ami-866d3ee6')
    @permissions_auditor_key_id     = ENV.fetch('BOSH_AWS_PERMISSIONS_AUDITOR_KEY_ID', nil)
    @permissions_auditor_secret_key = ENV.fetch('BOSH_AWS_PERMISSIONS_AUDITOR_SECRET_KEY', nil)

    @cpi_api_version                = ENV.fetch('BOSH_CPI_API_VERSION', 1).to_i

    logger = Bosh::Cpi::Logger.new(STDERR)
    Bosh::Clouds::Config.define_singleton_method(:logger) { logger }
    validate_minimum_permissions(logger)

    ec2_client = Aws::EC2::Client.new(
      region: @region,
      access_key_id: @access_key_id,
      secret_access_key: @secret_access_key,
      session_token: @session_token,
      logger: logger
    )
    @ec2 = Aws::EC2::Resource.new(client: ec2_client)
  end

  rspec_config.before(:each) do
    @registry = instance_double(Bosh::Cpi::RegistryClient).as_null_object
    allow(Bosh::Cpi::RegistryClient).to receive(:new).and_return(@registry)
    allow(@registry).to receive(:read_settings).and_return({})

    @cpi = Bosh::AwsCloud::CloudV1.new(
      'aws' => {
        'region' => @region,
        'default_key_name' => @default_key_name,
        'default_security_groups' => get_security_group_ids,
        'fast_path_delete' => 'yes',
        'access_key_id' => @access_key_id,
        'secret_access_key' => @secret_access_key,
        'session_token' => @session_token,
        'max_retries' => 8
      },
      'registry' => {
        'endpoint' => 'fake',
        'user' => 'fake',
        'password' => 'fake'
      },
    )

    if @cpi_api_version >= 2
      @cpi = Bosh::AwsCloud::CloudV2.new(
        @cpi_api_version,
        'aws' => {
          'region' => @region,
          'default_key_name' => @default_key_name,
          'default_security_groups' => get_security_group_ids,
          'fast_path_delete' => 'yes',
          'access_key_id' => @access_key_id,
          'secret_access_key' => @secret_access_key,
          'session_token' => @session_token,
          'max_retries' => 8
        },
        'registry' => {
          'endpoint' => 'fake',
          'user' => 'fake',
          'password' => 'fake'
        },
      )
    end

    @stemcell_id = create_stemcell
    @vpc_id = @ec2.subnet(@subnet_id).vpc_id

    puts "Running on cpi_version: #{@cpi_api_version} class: #{@cpi.class}"
  end

  rspec_config.after(:each) do
    delete_stemcell
  end
end

def vm_lifecycle(vm_disks: disks, ami_id: ami, cpi: @cpi)
  stemcell_properties = {
    'encrypted' => false,
    'ami' => {
      @region => ami_id
    }
  }
  stemcell_id = cpi.create_stemcell('/not/a/real/path', stemcell_properties)
  expect(stemcell_id).to end_with(' light')

  create_vm_response = cpi.create_vm(
    nil,
    stemcell_id,
    vm_type,
    network_spec,
    vm_disks,
    nil,
    )
  puts "=== create vm response: #{create_vm_response}"
  instance_id = create_vm_response

  # cpi check for custom cpi during tests
  if @cpi_api_version >= 2 && cpi == @cpi
    instance_id = create_vm_response['vm_cid']
  end
  
  expect(instance_id).not_to be_nil
  expect(cpi.has_vm?(instance_id)).to be(true)

  cpi.set_vm_metadata(instance_id, vm_metadata)

  yield(instance_id) if block_given?
ensure
  cpi.delete_vm(instance_id) if instance_id
  cpi.delete_stemcell(stemcell_id) if stemcell_id
  expect(@ec2.image(ami_id)).to exist
end

def get_security_group_names(subnet_id)
  security_groups = @ec2.subnet(subnet_id).vpc.security_groups
  security_groups.map { |sg| sg.group_name }
end

def get_root_block_device(root_device_name, block_devices)
  block_devices.find do |device|
    root_device_name.start_with?(device.device_name)
  end
end


def get_target_group_arn(name)
  elb_v2_client.describe_target_groups(names: [name]).target_groups[0].target_group_arn
end

def route_exists?(route_table, expected_cidr, instance_id)
  4.times do
    route_table.reload
    found_route = route_table.routes.any? { |r| r.destination_cidr_block == expected_cidr && r.instance_id == instance_id }
    return true if found_route
    sleep 0.5
  end

  false
end

def array_key_value_to_hash(arr_with_keys)
  hash = {}

  arr_with_keys.each do |obj|
    hash[obj.key] = obj.value
  end
  hash
end

class RegisteredInstances < StandardError; end

def ensure_no_instances_registered_with_elb(elb_client, elb_id)
  instances = elb_client.describe_load_balancers(load_balancer_names: [elb_id])[:load_balancer_descriptions]
    .first[:instances]

  raise RegisteredInstances unless instances.empty?
  true
end
