require 'spec_helper'
require 'integration/helpers/ec2_helper'

RSpec.configure do |rspec_config|
  include IntegrationHelpers

  rspec_config.before(:each) do
    @access_key_id      = ENV['BOSH_AWS_ACCESS_KEY_ID']       || raise('Missing BOSH_AWS_ACCESS_KEY_ID')
    @secret_access_key  = ENV['BOSH_AWS_SECRET_ACCESS_KEY']   || raise('Missing BOSH_AWS_SECRET_ACCESS_KEY')
    @subnet_id          = ENV['BOSH_AWS_SUBNET_ID']           || raise('Missing BOSH_AWS_SUBNET_ID')
    @subnet_zone        = ENV['BOSH_AWS_SUBNET_ZONE']         || raise('Missing BOSH_AWS_SUBNET_ZONE')
    @region             = ENV.fetch('BOSH_AWS_REGION', 'us-east-1')
    @default_key_name   = ENV.fetch('BOSH_AWS_DEFAULT_KEY_NAME', 'bosh')
    @ami                = ENV.fetch('BOSH_AWS_IMAGE_ID', 'ami-145a7603')

    logger = Logger.new(STDERR)
    ec2_client = Aws::EC2::Client.new(
      region:      @region,
      access_key_id: @access_key_id,
      secret_access_key: @secret_access_key,
      logger: logger,
    )
    @ec2 = Aws::EC2::Resource.new(client: ec2_client)

    @registry = instance_double(Bosh::Cpi::RegistryClient).as_null_object
    allow(Bosh::Cpi::RegistryClient).to receive(:new).and_return(@registry)
    allow(@registry).to receive(:read_settings).and_return({})
    allow(Bosh::Clouds::Config).to receive_messages(logger: logger)
    @cpi = Bosh::AwsCloud::Cloud.new(
      'aws' => {
        'region' => @region,
        'default_key_name' => @default_key_name,
        'default_security_groups' => get_security_group_ids,
        'fast_path_delete' => 'yes',
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

    @stemcell_id = create_stemcell
    @vpc_id = @ec2.subnet(@subnet_id).vpc_id
  end

  rspec_config.after(:each) do
    delete_stemcell
  end
end
