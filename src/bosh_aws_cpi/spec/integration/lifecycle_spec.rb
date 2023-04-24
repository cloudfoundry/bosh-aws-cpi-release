require 'integration/spec_helper'
require 'bosh/cpi/compatibility_helpers/delete_vm'
require 'tempfile'
require 'bosh/cpi/logger'
require 'cloud'

describe 'lifecycle test' do
  before(:all) do
    @manual_ip          = ENV.fetch('BOSH_AWS_LIFECYCLE_MANUAL_IP')
    @elb_id             = ENV.fetch('BOSH_AWS_ELB_ID')
    @target_group_name  = ENV.fetch('BOSH_AWS_TARGET_GROUP_NAME')
  end

  let(:instance_type_with_ephemeral)      { ENV.fetch('BOSH_AWS_INSTANCE_TYPE', 'm3.medium') }
  let(:instance_type_with_ephemeral_nvme) { ENV.fetch('BOSH_AWS_INSTANCE_TYPE_EPHEMERAL_NVME', 'i3.large') }
  let(:instance_type_without_ephemeral)   { ENV.fetch('BOSH_AWS_INSTANCE_TYPE_WITHOUT_EPHEMERAL', 't2.small') }
  let(:instance_type_ipv6)                { 't2.small' } # "IPv6 is not supported for the instance type 'm3.medium'"
  let(:ami)                               { hvm_ami }
  let(:hvm_ami)                           { ENV.fetch('BOSH_AWS_IMAGE_ID', 'ami-9c91b7fc') }
# let(:pv_ami)                            { ENV.fetch('BOSH_AWS_PV_IMAGE_ID', 'ami-3f71225f') }
  let(:windows_ami)                       { ENV.fetch('BOSH_AWS_WINDOWS_IMAGE_ID') }
  let(:eip)                               { ENV.fetch('BOSH_AWS_ELASTIC_IP') }
  let(:instance_type) { instance_type_with_ephemeral }
  let(:vm_metadata) { { deployment: 'deployment', job: 'cpi_spec', index: '0', delete_me: 'please' } }
  let(:disks) { [] }
  let(:network_spec) { {} }
  let(:vm_type) { { 'instance_type' => instance_type, 'availability_zone' => @subnet_zone } }
  let(:security_groups) { get_security_group_ids }
  let(:registry) { instance_double(Bosh::Cpi::RegistryClient).as_null_object }
  let(:mock_cpi_api_version) { 2 }

  let(:cpi_v2_options) {
    {
      'aws' => {
        'region' => @region,
        'default_key_name' => @default_key_name,
        'default_security_groups' => get_security_group_ids,
        'fast_path_delete' => 'yes',
        'access_key_id' => @access_key_id,
        'secret_access_key' => @secret_access_key,
        'session_token' => @session_token,
        'max_retries' => 8,
        'vm' => {'stemcell' => {'api_version' => 2}},
      },
    }
  }

  let(:cpi_v2) do
    Bosh::AwsCloud::CloudV2.new(cpi_v2_options)
  end

  before do
    allow(Bosh::Cpi::RegistryClient).to receive(:new).and_return(registry)
    allow(registry).to receive(:read_settings).and_return({})

    begin
      @ec2.instances(
        filters: [
          { name: 'tag-key', values: ['delete_me'] },
          { name: 'instance-state-name', values: %w(stopped stopping running pending) }
        ]
      ).each(&:terminate)
    rescue Aws::EC2::Errors::InvalidInstanceIdNotFound
      # don't blow up tests if instance that we're trying to delete was not found
    end
    allow(Bosh::Clouds::Config).to receive_messages(logger: logger)
  end

  let(:logs) { STDOUT }
  let(:logger) {Bosh::Cpi::Logger.new(logs) }


  extend Bosh::Cpi::CompatibilityHelpers

  context 'when config does not have registry settings' do
    let(:cpi_options) {
      {
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
      }
    }

    let(:network_spec) do
      {
        'default' => {
          'type' => 'dynamic',
          'cloud_properties' => { 'subnet' => @subnet_id }
        }
      }
    end

    it 'raises an error' do
      cpi = Bosh::AwsCloud::CloudV1.new(cpi_options)
      expect { cpi.create_vm('agent_id', 'stemcell_id', 'vm_type', 'network') }.to raise_error(/Cannot create VM without registry with CPI v1. Registry not configured./)
    end

    context 'stemcell is specified as v2' do
      it 'does not raise an error when cloudv2 is used' do
        expect { vm_lifecycle(cpi: cpi_v2) }.to_not raise_error
      end
    end

    context 'environment contains tags' do
      it 'creates a vm with tags' do
        environment = { 'bosh' => { 'tags' => { 'tag1' => 'value1' } } }
        instance_id, _ = cpi_v2.create_vm(nil, @stemcell_id, vm_type, network_spec, disks, environment)
        instance = cpi_v2.ec2_resource.instance(instance_id)
        expect(instance.tags).to_not be_nil
      end
    end

    context 'stemcell is specified as v1' do
      let(:cpi_options) {
        {
          'aws' => {
            'region' => @region,
            'default_key_name' => @default_key_name,
            'default_security_groups' => get_security_group_ids,
            'fast_path_delete' => 'yes',
            'access_key_id' => @access_key_id,
            'secret_access_key' => @secret_access_key,
            'session_token' => @session_token,
            'max_retries' => 8,
            'vm' => {'stemcell' => {'api_version' => 1}},
          },
        }
      }

      it 'raises an error due to attempting to use the registry' do
        cpi = Bosh::AwsCloud::CloudV2.new(cpi_options)
        expect { cpi.create_vm('agent_id', 'stemcell_id', 'vm_type', 'network') }.to raise_error(/Cannot create VM without registry with CPI v2 and stemcell api version 1. Registry not configured./)
      end
    end

    context 'stemcell is not specified' do
      it 'raises an error due to attempting to use the registry' do
        cpi = Bosh::AwsCloud::CloudV2.new(cpi_options)
        expect { cpi.create_vm('agent_id', 'stemcell_id', 'vm_type', 'network') }.to raise_error(/Cannot create VM without registry with CPI v2 and stemcell api version 1. Registry not configured./)
      end
    end
  end

  describe 'instantiating the CPI with invalid endpoint or region' do
    it 'raises an Bosh::Clouds::CloudError' do
      expect do
        cpi = Bosh::AwsCloud::CloudV2.new('aws' => {
          'region' => 'invalid-region',
          'default_key_name' => 'blah',
          'default_security_groups' => 'blah',
          'fast_path_delete' => 'yes',
          'access_key_id' => @access_key_id,
          'secret_access_key' => @secret_access_key,
          'session_token' => @session_token,
          'max_retries' => 0
        },
        'registry' => {
          'endpoint' => 'fake',
          'user' => 'fake',
          'password' => 'fake'
        },
        'debug'=> {
          'cpi'=> {
            'api_version'=> mock_cpi_api_version
          },
        })
        cpi.has_vm?('my-vm')
      end.to raise_error(/region/)
    end
  end

  context 'using STS credentials' do

    let(:sts_cpi) do
      sts_client = Aws::STS::Client.new(
        :region => @region,
        :access_key_id => @access_key_id,
        :secret_access_key => @secret_access_key,
        :session_token => @session_token,
      )
      session = sts_client.get_session_token(duration_seconds: 900).to_h[:credentials]

      @cpi.class.new(
        'aws' => {
          'region' => @region,
          'default_key_name' => @default_key_name,
          'fast_path_delete' => 'yes',
          'access_key_id' => session[:access_key_id],
          'secret_access_key' => session[:secret_access_key],
          'session_token' => session[:session_token],
          'max_retries' => 8
        },
        'registry' => {
          'endpoint' => 'fake',
          'user' => 'fake',
          'password' => 'fake'
        },
        'debug'=> {
          'cpi'=> {
            'api_version'=> mock_cpi_api_version
          },
        },
      )
    end
    it 'it can perform a AWS API call', :focus => true do
      skip("Already using STS credentials") unless @session_token.nil? || @session_token == ""

      expect {
        sts_cpi.delete_disk('vol-4c68780b')
      }.to raise_error Bosh::Clouds::DiskNotFound
    end
  end

  context 'using AssumeRole credentials' do
    let(:sts_cpi) do
      region = ENV.fetch('BOSH_AWS_REGION', 'us-west-1')
      access_key_id =  ENV.fetch('BOSH_AWS_ACCESS_KEY_ID')
      secret_access_key = ENV.fetch('BOSH_AWS_SECRET_ACCESS_KEY')
      session_token = ENV.fetch('BOSH_AWS_SESSION_TOKEN', nil)
      role_arn = ENV.fetch('BOSH_AWS_ROLE_ARN')

      @cpi.class.new(
        'aws' => {
          'region' => region,
          'default_key_name' => @default_key_name,
          'fast_path_delete' => 'yes',
          'access_key_id' => access_key_id,
          'secret_access_key' => secret_access_key,
          'role_arn' => role_arn,
          'session_token' => session_token,
          'max_retries' => 8
        },
        'registry' => {
          'endpoint' => 'fake',
          'user' => 'fake',
          'password' => 'fake'
        },
        'debug'=> {
          'cpi'=> {
            'api_version'=> mock_cpi_api_version
          },
        },
      )
    end
    it 'it can perform an AWS API call', :focus => true do
      skip("'BOSH_AWS_ROLE_ARN' Role ARN not provided, skipping assume role test") if ENV.fetch('BOSH_AWS_ROLE_ARN', nil).nil? || ENV.fetch('BOSH_AWS_ROLE_ARN') == ""

      expect {
        sts_cpi.delete_disk('vol-4c68780b')
      }.to raise_error Bosh::Clouds::DiskNotFound

      expect(sts_cpi.ec2_resource.client.config.credentials).to be_a(Aws::AssumeRoleCredentials)
    end
  end

  describe 'deleting things that no longer exist' do
    it 'raises the appropriate Clouds::Error' do
      # pass in *real* previously deleted ids instead of made up ones
      # because AWS returns Malformed/Invalid errors for fake ids
      expect {
        @cpi.delete_vm('i-49f9f169')
      }.to raise_error Bosh::Clouds::VMNotFound

      expect {
        @cpi.delete_disk('vol-4c68780b')
      }.to raise_error Bosh::Clouds::DiskNotFound
    end
  end

  context 'dynamic networking' do
    let(:network_spec) do
      {
        'default' => {
          'type' => 'dynamic',
          'cloud_properties' => { 'subnet' => @subnet_id }
        }
      }
    end

    it 'can exercise the vm lifecycle' do
      vm_lifecycle
    end

    context 'with advertised_routes' do
      let(:route_destination) { '9.9.9.9/32' }
      let!(:route_table_id) do
        ENV.fetch('BOSH_AWS_ADVERTISED_ROUTE_TABLE')
      end
      let(:vm_type) do
        {
          'instance_type' => instance_type,
          'availability_zone' => @subnet_zone,
          'advertised_routes' => [
            {
              'table_id' => route_table_id,
              'destination' => route_destination,
            }
          ]
        }
      end

      it 'associates the route to the created instance' do
        route_table = @cpi.ec2_resource.route_table(route_table_id)
        expect(route_table).to_not be_nil, "Could not found route table with id '#{route_table_id}'"

        vm_lifecycle do |instance_id|
          expect(route_exists?(route_table, route_destination, instance_id)).to be(true), "Expected to find route with destination '#{route_destination}', but did not"
        end
      end

      it 'updates the route if the route already exists' do
        route_table = @cpi.ec2_resource.route_table(route_table_id)
        expect(route_table).to_not be_nil, "Could not found route table with id '#{route_table_id}'"

        vm_lifecycle do |original_instance_id|
          expect(route_exists?(route_table, route_destination, original_instance_id)).to be(true), "Expected to find route with destination '#{route_destination}', but did not"\

          vm_lifecycle do |instance_id|
            expect(route_exists?(route_table, route_destination, instance_id)).to be(true), "Expected to find route with destination '#{route_destination}', but did not"
          end
        end
      end
    end

    it 'sets source_dest_check to true by default' do
      vm_lifecycle do |instance_id|
        instance = @cpi.ec2_resource.instance(instance_id)

        expect(instance.source_dest_check).to be(true)
      end
    end

    context 'with source_dest_check disabled' do
      let(:vm_type) do
        {
          'instance_type' => instance_type,
          'availability_zone' => @subnet_zone,
          'source_dest_check' => false
        }
      end

      it 'modifies the instance to disable source_dest_check' do
        vm_lifecycle do |instance_id|
          instance = @cpi.ec2_resource.instance(instance_id)

          expect(instance.source_dest_check).to be(false)
        end
      end
    end

    context 'with security groups names' do
      let(:sg_name_cpi) do
        @cpi.class.new(
          {
            'aws' => {
              'default_security_groups' => get_security_group_names(@subnet_id),
              'region' => @region,
              'default_key_name' => @default_key_name,
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
            'debug'=> {
              'cpi'=> {
                'api_version'=> mock_cpi_api_version
              },
            },
          }
        )
      end

      it 'can exercise the vm lifecycle' do
        vm_lifecycle(cpi: sg_name_cpi)
      end
    end
  end

  context 'vip networking' do
    let(:network_spec) do
      {
        'default' => {
          'type' => 'manual',
          'ip' => @manual_ip, # use different IP to avoid race condition
          'cloud_properties' => { 'subnet' => @subnet_id }
        },
        'elastic' => {
          'type' => 'vip',
          'ip' => eip
        }
      }
    end

    it 'can exercise the vm lifecycle' do
      vm_lifecycle
    end
  end

  context 'when auto_assign_public_ip is true' do
    let(:vm_type) do
      {
        'instance_type' => instance_type,
        'availability_zone' => @subnet_zone,
        'auto_assign_public_ip' => true
      }
    end
    let(:network_spec) do
      {
        'default' => {
          'type' => 'dynamic',
          'cloud_properties' => { 'subnet' => @subnet_id }
        }
      }
    end
    it 'assigns a public IP to the instance' do
      begin
        vm_lifecycle do |instance_id|
          begin
            expect(@cpi.ec2_resource.instance(instance_id).public_ip_address).to_not be_nil
          end
        end
      end
    end
  end

  context 'set_disk_metadata' do
    before(:each) do
      @volume_id = @cpi.create_disk(2048, {})
    end

    after(:each) do
      @cpi.delete_disk(@volume_id) if @volume_id
    end

    let(:disk_metadata) do
      {
          'deployment' => 'deployment',
          'job' => 'cpi_spec',
          'index' => '0',
          'delete_me' => 'please'
      }
    end

    it 'sets the disk metadata accordingly' do
      volume = @cpi.ec2_resource.volume(@volume_id)
      expect(array_key_value_to_hash(volume.tags)).not_to include(disk_metadata)

      @cpi.set_disk_metadata(@volume_id, disk_metadata)

      volume = @cpi.ec2_resource.volume(@volume_id)
      expect(array_key_value_to_hash(volume.tags)).to include(disk_metadata)
    end
  end

  context 'delete_snapshot' do
    it 'should NOT fail if snapshot does not exist' do
      expect {
        @cpi.delete_snapshot("snap-078df69092d3eb2cb")
      }.to_not raise_error
    end
  end
end
