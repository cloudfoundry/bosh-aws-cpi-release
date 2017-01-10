require 'spec_helper'
require 'bosh/cpi/compatibility_helpers/delete_vm'
require 'tempfile'
require 'logger'
require 'cloud'
require 'pry-byebug'

describe Bosh::AwsCloud::Cloud do
  before(:all) do
    @access_key_id     = ENV['BOSH_AWS_ACCESS_KEY_ID']       || raise('Missing BOSH_AWS_ACCESS_KEY_ID')
    @secret_access_key = ENV['BOSH_AWS_SECRET_ACCESS_KEY']   || raise('Missing BOSH_AWS_SECRET_ACCESS_KEY')
    @subnet_id         = ENV['BOSH_AWS_SUBNET_ID']           || raise('Missing BOSH_AWS_SUBNET_ID')
    @subnet_zone       = ENV['BOSH_AWS_SUBNET_ZONE']         || raise('Missing BOSH_AWS_SUBNET_ZONE')
    @manual_ip         = ENV['BOSH_AWS_LIFECYCLE_MANUAL_IP'] || raise('Missing BOSH_AWS_LIFECYCLE_MANUAL_IP')
    @elb_id            = ENV['BOSH_AWS_ELB_ID']              || raise('Missing BOSH_AWS_ELB_ID')
    @kms_key_arn       = ENV['BOSH_AWS_KMS_KEY_ARN']         || raise('Missing BOSH_AWS_KMS_KEY_ARN')
    @region            = ENV['BOSH_AWS_REGION']              || 'us-east-1'
  end

  let(:instance_type_with_ephemeral)    { ENV.fetch('BOSH_AWS_INSTANCE_TYPE', 'm3.medium') }
  let(:instance_type_without_ephemeral) { ENV.fetch('BOSH_AWS_INSTANCE_TYPE_WITHOUT_EPHEMERAL', 't2.small') }
  let(:default_key_name)                { ENV.fetch('BOSH_AWS_DEFAULT_KEY_NAME', 'bosh')}
  let(:ami)                             { hvm_ami }
  let(:hvm_ami)                         { ENV.fetch('BOSH_AWS_IMAGE_ID', 'ami-145a7603') }
  let(:pv_ami)                          { ENV.fetch('BOSH_AWS_PV_IMAGE_ID', 'ami-d4c6e2c3') }
  let(:windows_ami)                     { ENV.fetch('BOSH_AWS_WINDOWS_IMAGE_ID', 'ami-8927779e') }
  let(:instance_type) { instance_type_with_ephemeral }
  let(:vm_metadata) { { deployment: 'deployment', job: 'cpi_spec', index: '0', delete_me: 'please' } }
  let(:disks) { [] }
  let(:network_spec) { {} }
  let(:vm_type) { { 'instance_type' => instance_type, 'availability_zone' => @subnet_zone } }
  let(:registry) { instance_double(Bosh::Cpi::RegistryClient).as_null_object }
  let(:security_groups) { get_security_group_ids(@subnet_id) }

  before {
    allow(Bosh::Cpi::RegistryClient).to receive(:new).and_return(registry)
    allow(registry).to receive(:read_settings).and_return({})
  }

  # Use subject-bang because AWS SDK needs to be reconfigured
  # with a current test's logger before new Aws::EC2 object is created.
  # Reconfiguration happens via `AWS.config`.
  subject!(:cpi) do
    described_class.new(
      'aws' => {
        'region' => @region,
        'default_key_name' => default_key_name,
        'default_security_groups' => security_groups,
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
  end

  before do
    begin
      ec2_client = Aws::EC2::Client.new(
        credentials: Aws::Credentials.new(@access_key_id, @secret_access_key),
        logger:      Logger.new(STDERR),
      )
      Aws::EC2::Resource.new(client: ec2_client).instances({
        filters: [ { name: 'tag-key', values: ['delete_me'] } ],
      }).each(&:terminate)
    rescue Aws::EC2::Errors::InvalidInstanceIdNotFound
      # don't blow up tests if instance that we're trying to delete was not found
    end
  end

  before { allow(Bosh::Clouds::Config).to receive_messages(logger: logger) }
  let(:logger) { Logger.new(STDERR) }

  extend Bosh::Cpi::CompatibilityHelpers

  describe 'instantiating the CPI with invalid endpoint or region' do
    it 'raises an Bosh::Clouds::CloudError' do
      expect do
        described_class.new('aws' => {
          'region' => 'invalid-region',
          'default_key_name' => 'blah',
          'default_security_groups' => 'blah',
          'fast_path_delete' => 'yes',
          'access_key_id' => @access_key_id,
          'secret_access_key' => @secret_access_key,
          'max_retries' => 0
        },
        'registry' => {
          'endpoint' => 'fake',
          'user' => 'fake',
          'password' => 'fake'
        })
      end.to raise_error(/region/)
    end
  end

  describe 'deleting things that no longer exist' do
    it 'raises the appropriate Clouds::Error' do
      # pass in *real* previously deleted ids instead of made up ones
      # because AWS returns Malformed/Invalid errors for fake ids
      expect {
        cpi.delete_vm('i-49f9f169')
      }.to raise_error Bosh::Clouds::VMNotFound

      expect {
        cpi.delete_disk('vol-4c68780b')
      }.to raise_error Bosh::Clouds::DiskNotFound
    end
  end

  context 'manual networking' do
    let(:network_spec) do
      {
        'default' => {
          'type' => 'manual',
          'ip' => @manual_ip, # use different IP to avoid race condition
          'cloud_properties' => { 'subnet' => @subnet_id }
        }

      }
    end

    context 'vm_type specifies elb for instance' do
      let(:vm_type) do
        {
          'instance_type' => instance_type,
          'availability_zone' => @subnet_zone,
          'elbs' => [@elb_id]
        }
      end
      let(:endpoint_configured_cpi) do
        described_class.new(
          'aws' => {
            'ec2_endpoint' => "https://ec2.#{@region}.amazonaws.com",
            'elb_endpoint' => "https://elasticloadbalancing.#{@region}.amazonaws.com",
            'default_key_name' => default_key_name,
            'default_security_groups' => security_groups,
            'fast_path_delete' => 'yes',
            'access_key_id' => @access_key_id,
            'secret_access_key' => @secret_access_key,
            'region' => @region,
            'max_retries' => 8
          },
          'registry' => {
            'endpoint' => 'fake',
            'user' => 'fake',
            'password' => 'fake'
          }
        )
      end

      it 'registers new instance with elb' do
        begin
          stemcell_id = endpoint_configured_cpi.create_stemcell('/not/a/real/path', {'ami' => {@region => ami}})
          vm_id = endpoint_configured_cpi.create_vm(
            nil,
            stemcell_id,
            vm_type,
            network_spec,
            nil,
          )

          aws_params = {
            access_key_id: @access_key_id,
            secret_access_key: @secret_access_key,
            region: @region,
          }

          elb_client = Aws::ElasticLoadBalancing::Client.new(aws_params)
          instance_ids = elb_client.describe_load_balancers({:load_balancer_names => [@elb_id]}).load_balancer_descriptions
                        .first.instances.map { |i| i.instance_id }

          expect(instance_ids).to include(vm_id)

          endpoint_configured_cpi.delete_vm(vm_id)

          vm_id=nil

          retry_options = { sleep: 10, tries: 10, on: RegisteredInstances }

          logger.debug('Waiting for deregistration from ELB')
          expect {
            Bosh::Common.retryable(retry_options) do |tries, error|
              ensure_no_instances_registered_with_elb(logger, elb_client, @elb_id)
            end
          }.to_not raise_error

          instances = elb_client.describe_load_balancers({:load_balancer_names => [@elb_id]}).load_balancer_descriptions
                        .first.instances

          expect(instances).to be_empty
        ensure
          endpoint_configured_cpi.delete_stemcell(stemcell_id) if stemcell_id
          endpoint_configured_cpi.delete_vm(vm_id) if vm_id
        end
      end
    end

    context 'without existing disks' do
      it 'should exercise the vm lifecycle' do
        vm_lifecycle do |instance_id|
          begin
            volume_id = cpi.create_disk(2048, {}, instance_id)
            expect(volume_id).not_to be_nil
            expect(cpi.has_disk?(volume_id)).to be(true)

            cpi.attach_disk(instance_id, volume_id)

            snapshot_metadata = vm_metadata.merge(
              bosh_data: 'bosh data',
              instance_id: 'instance',
              agent_id: 'agent',
              director_name: 'Director',
              director_uuid: '6d06b0cc-2c08-43c5-95be-f1b2dd247e18',
            )
            snapshot_id = cpi.snapshot_disk(volume_id, snapshot_metadata)
            expect(snapshot_id).not_to be_nil

            snapshot = cpi.ec2_resource.snapshot(snapshot_id)
            snapshot_tags = array_key_value_to_hash(snapshot.tags)
            expect(snapshot_tags['device']).to eq '/dev/sdf'
            expect(snapshot_tags['agent_id']).to eq 'agent'
            expect(snapshot_tags['instance_id']).to eq 'instance'
            expect(snapshot_tags['director_name']).to eq 'Director'
            expect(snapshot_tags['director_uuid']).to eq '6d06b0cc-2c08-43c5-95be-f1b2dd247e18'
            expect(snapshot_tags['Name']).to eq 'deployment/cpi_spec/0/sdf'

          ensure
            cpi.delete_snapshot(snapshot_id) if snapshot_id
            Bosh::Common.retryable(tries: 20, on: Bosh::Clouds::DiskNotAttached, sleep: lambda { |n, _| [2**(n-1), 30].min }) do
              cpi.detach_disk(instance_id, volume_id) if instance_id && volume_id
              true
            end
            cpi.delete_disk(volume_id) if volume_id
          end
        end
      end
    end

    context 'with existing disks' do
      it 'can exercise the vm lifecycle and list the disks' do
        begin
          volume_id = nil
          vm_lifecycle do |instance_id|
            begin
              volume_id = cpi.create_disk(2048, {}, instance_id)
              expect(volume_id).not_to be_nil
              expect(cpi.has_disk?(volume_id)).to be(true)

              cpi.attach_disk(instance_id, volume_id)
              expect(cpi.get_disks(instance_id)).to include(volume_id)
            ensure
              Bosh::Common.retryable(tries: 20, on: Bosh::Clouds::DiskNotAttached, sleep: lambda { |n, _| [2**(n-1), 30].min }) do
                cpi.detach_disk(instance_id, volume_id)
                true
              end
            end
          end
          vm_options = {
            :disks => [volume_id]
          }
          vm_lifecycle(vm_options) do |instance_id|
            begin
              cpi.attach_disk(instance_id, volume_id)
              expect(cpi.get_disks(instance_id)).to include(volume_id)
            ensure
              Bosh::Common.retryable(tries: 20, on: Bosh::Clouds::DiskNotAttached, sleep: lambda { |n, _| [2**(n-1), 30].min }) do
                cpi.detach_disk(instance_id, volume_id)
                true
              end
            end
          end
        ensure
          cpi.delete_disk(volume_id) if volume_id
        end
      end
    end

    context 'when disk_pool.cloud_properties are empty' do
      let(:cloud_properties) { {} }

      it 'creates an unencrypted gp2 disk of the specified size' do
        begin
          volume_id = cpi.create_disk(2048, cloud_properties)
          expect(volume_id).not_to be_nil
          expect(cpi.has_disk?(volume_id)).to be(true)

          volume = cpi.ec2_resource.volume(volume_id)
          expect(volume.encrypted).to be(false)
          expect(volume.volume_type).to eq('gp2')
          expect(volume.size).to eq(2)
        ensure
          cpi.delete_disk(volume_id) if volume_id
        end
      end
    end

    context 'when disk_pool specifies a disk type' do
      let(:cloud_properties) { {'type' => 'standard'} }

      it 'creates a disk of the given type' do
        begin
          volume_id = cpi.create_disk(2048, cloud_properties)
          expect(volume_id).not_to be_nil
          expect(cpi.has_disk?(volume_id)).to be(true)

          volume = cpi.ec2_resource.volume(volume_id)
          expect(volume.volume_type).to eq('standard')
        ensure
          cpi.delete_disk(volume_id) if volume_id
        end
      end
    end

    context 'when encrypted is true' do
      let(:cloud_properties) { {'encrypted' => true} }
      it 'can create encrypted disks' do
        begin
          volume_id = cpi.create_disk(2048, cloud_properties)
          expect(volume_id).not_to be_nil
          expect(cpi.has_disk?(volume_id)).to be(true)

          encrypted_volume = cpi.ec2_resource.volume(volume_id)
          expect(encrypted_volume.encrypted).to be(true)
        ensure
          cpi.delete_disk(volume_id) if volume_id
        end
      end

      context 'and kms_key_arn is specified' do
        before do
          cloud_properties['kms_key_arn'] = @kms_key_arn
        end

        it 'creates an encrypted persistent disk' do
          begin
            volume_id = cpi.create_disk(2048, cloud_properties)
            expect(volume_id).not_to be_nil
            expect(cpi.has_disk?(volume_id)).to be(true)

            encrypted_volume = cpi.ec2_resource.volume(volume_id)
            expect(encrypted_volume.kms_key_id).to eq(@kms_key_arn)
          ensure
            cpi.delete_disk(volume_id) if volume_id
          end
        end
      end
    end

    it 'can create optimized magnetic disks' do
      begin
        minimum_magnetic_disk_size = 500 * 1024
        volume_id = cpi.create_disk(minimum_magnetic_disk_size, {'type' => 'sc1'})
        expect(volume_id).not_to be_nil
        expect(cpi.has_disk?(volume_id)).to be(true)

        volume = cpi.ec2_resource.volume(volume_id)
        expect(volume.volume_type).to eq('sc1')
      ensure
        cpi.delete_disk(volume_id) if volume_id
      end
    end

    context 'when ephemeral_disk properties are specified' do
      let(:vm_type) do
        {
          'instance_type' => instance_type,
          'availability_zone' => @subnet_zone,
          'ephemeral_disk' => {
            'size' => 4 * 1024,
          }
        }
      end
      let(:instance_type) { instance_type_without_ephemeral }

      it 'requests ephemeral disk with the specified size' do
        vm_lifecycle do |instance_id|
          disks = cpi.get_disks(instance_id)
          expect(disks.size).to eq(2)

          ephemeral_volume = cpi.ec2_resource.volume(disks[1])
          expect(ephemeral_volume.size).to eq(4)
          expect(ephemeral_volume.volume_type).to eq('gp2')
          expect(ephemeral_volume.encrypted).to eq(false)
        end
      end

      context 'when iops are specified' do
        let(:vm_type) do
          {
            'instance_type' => instance_type,
            'availability_zone' => @subnet_zone,
            'ephemeral_disk' => {
              'size' => 4 * 1024,
              'type' => 'io1',
              'iops' => 100
            }
          }
        end

        it 'requests ephemeral disk with the specified iops' do
          vm_lifecycle do |instance_id|
            disks = cpi.get_disks(instance_id)
            expect(disks.size).to eq(2)

            ephemeral_volume = cpi.ec2_resource.volume(disks[1])
            expect(ephemeral_volume.size).to eq(4)
            expect(ephemeral_volume.volume_type).to eq('io1')
            expect(ephemeral_volume.iops).to eq(100)

            expect(ephemeral_volume.encrypted).to eq(false)
          end
        end
      end

      context 'when ephemeral_disk.use_instance_storage is true' do
        let(:vm_type) do
          {
            'instance_type' => instance_type,
            'availability_zone' => @subnet_zone,
            'ephemeral_disk' => {
              'use_instance_storage' => true
            }
          }
        end
        let(:instance_type) { instance_type_with_ephemeral }

        it 'should not contain a block_device_mapping for /dev/sdb' do
          vm_lifecycle do |instance_id|
            block_device_mapping = cpi.ec2_resource.instance(instance_id).block_device_mappings
            ebs_ephemeral = block_device_mapping.any? {|entry| entry.device_name == '/dev/sdb'}

            expect(ebs_ephemeral).to eq(false)
          end
        end
      end

      context 'when encrypted is true' do
        let(:vm_type) do
          {
            'instance_type' => instance_type,
            'availability_zone' => @subnet_zone,
            'ephemeral_disk' => {
              'size' => 4 * 1024,
              'type' => 'io1',
              'iops' => 100,
              'encrypted' => true
            }
          }
        end
        let(:instance_type) { instance_type_without_ephemeral }

        it 'creates an encrypted ephemeral disk' do
          vm_lifecycle do |instance_id|
            block_device_mapping = cpi.ec2_resource.instance(instance_id).block_device_mappings
            ephemeral_block_device = block_device_mapping.find {|entry| entry.device_name == '/dev/sdb'}

            ephemeral_disk = cpi.ec2_resource.volume(ephemeral_block_device.ebs.volume_id)

            expect(ephemeral_disk.encrypted).to eq(true)
          end
        end

        context 'when the instance_type does not support encryption' do
          let(:instance_type) { 't1.micro' }
          let(:ami) { 'ami-3ec82656' }
          it 'raises an exception' do
            expect { vm_lifecycle }.to raise_error
          end
        end
      end
    end

    context 'when raw_instance_storage is true' do
      let(:vm_type) do
        {
          'instance_type' => instance_type,
          'availability_zone' => @subnet_zone,
          'raw_instance_storage' => true,
          'ephemeral_disk' => {
              'size' => 4 * 1024
          }
        }
      end
      let(:instance_type) { instance_type_with_ephemeral }

      it 'requests all available instance disks and puts the mappings in the registry' do
        vm_lifecycle do |instance_id|
          expect(registry).to have_received(:update_settings).with(instance_id, hash_including({
                'disks' => {
                    'system' => '/dev/xvda',
                    'persistent' => {},
                    'ephemeral' => '/dev/sdb',
                    'raw_ephemeral' => [{'path' => '/dev/xvdba'}]
                }
            }))
        end
      end

      describe 'root device configuration' do
        let(:root_disk_size) { nil }
        let(:root_disk_type) { nil }

        context 'when root_disk properties are omitted' do
          context 'and AMI is hvm' do
            let(:root_disk_vm_props) do
              { ami: hvm_ami }
            end

            it 'requests root disk with the default type and size' do
              verify_root_disk_properties
            end
          end

          context 'and AMI is paravirtual' do
            let(:root_disk_vm_props) do
              { ami: pv_ami }
            end

            it 'requests root disk with the default type and size' do
              verify_root_disk_properties
            end
          end

          context 'and AMI is Windows' do
            let(:root_disk_vm_props) do
              { ami: windows_ami }
            end

            it 'requests root disk with the default type and size' do
              verify_root_disk_properties
            end
          end
        end

        context 'when root_disk properties are specified' do
          let(:root_disk_size) { 30 * 1024 }
          let(:vm_type) do
            {
              'instance_type' => instance_type,
              'availability_zone' => @subnet_zone,
              'root_disk' => {
                'size' => root_disk_size,
              }
            }
          end

          context 'and AMI is hvm' do
            let(:root_disk_vm_props) do
              { ami: ami }
            end

            it 'requests root disk with the specified size and type gp2' do
              verify_root_disk_properties
            end
          end

          context 'and AMI is pv' do
            let(:root_disk_vm_props) do
              { ami: pv_ami }
            end

            it 'requests root disk with the specified size and type gp2' do
              verify_root_disk_properties
            end
          end

          context 'and AMI is Windows' do
            let(:root_disk_vm_props) do
              { ami: windows_ami }
            end

            it 'requests root disk with the specified size and type gp2' do
              verify_root_disk_properties
            end
          end

          context 'and type is specified' do
            let(:root_disk_type) { 'standard' }
            let(:vm_type) do
              {
                'instance_type' => instance_type,
                'availability_zone' => @subnet_zone,
                'root_disk' => {
                  'size' => root_disk_size,
                  'type' => root_disk_type,
                }
              }
            end

            context 'and AMI is hvm' do
              let(:root_disk_vm_props) do
                { ami: ami }
              end

              it 'requests root disk with the specified size and type gp2' do
                verify_root_disk_properties
              end
            end

            context 'and AMI is pv' do
              let(:root_disk_vm_props) do
                { ami: pv_ami }
              end

              it 'requests root disk with the specified size and type gp2' do
                verify_root_disk_properties
              end
            end

            context 'and AMI is Windows' do
              let(:root_disk_vm_props) do
                { ami: windows_ami }
              end

              it 'requests root disk with the specified size and type gp2' do
                verify_root_disk_properties
              end
            end
          end
        end

        def verify_root_disk_properties
          target_ami = get_ami(root_disk_vm_props[:ami])
          ami_root_device = get_root_block_device(target_ami.root_device_name, target_ami.block_device_mappings)

          ami_root_volume_size = ami_root_device.ebs.volume_size
          expect(ami_root_volume_size).to be > 0

          vm_lifecycle(root_disk_vm_props) do |instance_id|
            instance = cpi.ec2_resource.instance(instance_id)
            instance_root_device = get_root_block_device(instance.root_device_name, instance.block_device_mappings)

            root_volume = cpi.ec2_resource.volume(instance_root_device.ebs.volume_id)

            if root_disk_size
              expect(root_volume.size).to eq(root_disk_size / 1024)
            else
              expect(root_volume.size).to eq(ami_root_volume_size)
            end
            if root_disk_type
              expect(root_volume.volume_type).to eq(root_disk_type)
            else
              expect(root_volume.volume_type).to eq('gp2')
            end
          end
        end

        def get_root_block_device(root_device_name, block_devices)
          block_devices.find do |device|
            root_device_name.start_with?(device.device_name)
          end
        end
      end
    end

    context 'when vm with attached disk is removed' do
      it 'should wait for 10 mins to attach disk/delete disk ignoring VolumeInUse error' do
        begin
          stemcell_id = cpi.create_stemcell('/not/a/real/path', {'ami' => {@region => ami}})
          vm_id = cpi.create_vm(
            nil,
            stemcell_id,
            vm_type,
            network_spec,
            [],
            nil,
          )

          disk_id = cpi.create_disk(2048, {}, vm_id)
          expect(cpi.has_disk?(disk_id)).to be(true)

          cpi.attach_disk(vm_id, disk_id)
          expect(cpi.get_disks(vm_id)).to include(disk_id)

          cpi.delete_vm(vm_id)
          vm_id = nil

          new_vm_id = cpi.create_vm(
            nil,
            stemcell_id,
            vm_type,
            network_spec,
            [disk_id],
            nil,
          )

          expect {
            cpi.attach_disk(new_vm_id, disk_id)
          }.to_not raise_error

          expect(cpi.get_disks(new_vm_id)).to include(disk_id)
        ensure
          cpi.delete_vm(new_vm_id) if new_vm_id
          cpi.delete_disk(disk_id) if disk_id
          cpi.delete_stemcell(stemcell_id) if stemcell_id
          cpi.delete_vm(vm_id) if vm_id
        end
      end
    end

    it 'will not raise error when detaching a non-existing disk' do
      # Detaching a non-existing disk from vm should NOT raise error
      vm_lifecycle do |instance_id|
        expect {
          # long-gone volume id used, avoids `Aws::EC2::Errors::InvalidParameterValue`
          cpi.detach_disk(instance_id, 'vol-092cfeeb61c2cf243')
        }.to_not raise_error
      end
    end

    context '#set_vm_metadata' do
      it 'correctly sets the tags set by #set_vm_metadata' do
        vm_lifecycle do |instance_id|
          instance = cpi.ec2_resource.instance(instance_id)
          tags = array_key_value_to_hash(instance.tags)
          expect(tags['deployment']).to eq('deployment')
          expect(tags['job']).to eq('cpi_spec')
          expect(tags['index']).to eq('0')
          expect(tags['delete_me']).to eq('please')
        end
      end
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
      let(:route_table_id) do
        vpc_id = cpi.ec2_resource.subnet(@subnet_id).vpc_id
        rt = cpi.ec2_resource.client.create_route_table({
          vpc_id: vpc_id,
        }).route_table
        expect(rt).to_not be_nil
        rt.route_table_id
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

      after(:each) do
        cpi.ec2_resource.client.delete_route_table({ route_table_id: route_table_id })
      end

      it 'associates the route to the created instance' do
        route_table = cpi.ec2_resource.route_table(route_table_id)
        expect(route_table).to_not be_nil, "Could not found route table with id '#{route_table_id}'"

        vm_lifecycle do |instance_id|
          found_route = route_table.routes.any? { |r| r.destination_cidr_block == route_destination && r.instance_id == instance_id }
          expect(found_route).to be(true), "Expected to find route with destination '#{route_destination}', but did not"
        end
      end

      it 'updates the route if the route already exists' do
        route_table = cpi.ec2_resource.route_table(route_table_id)
        expect(route_table).to_not be_nil, "Could not found route table with id '#{route_table_id}'"

        vm_lifecycle do |original_instance_id|
          found_route = route_table.routes.any? { |r| r.destination_cidr_block == route_destination && r.instance_id == original_instance_id }
          expect(found_route).to be(true), "Expected to find route with destination '#{route_destination}', but did not"

          vm_lifecycle do |instance_id|
            route_table.reload
            found_route = route_table.routes.any? { |r| r.destination_cidr_block == route_destination && r.instance_id == instance_id }
            expect(found_route).to be(true), "Expected to find route with destination '#{route_destination}', but did not"
          end
        end
      end
    end

    it 'sets source_dest_check to true by default' do
      vm_lifecycle do |instance_id|
        instance = cpi.ec2_resource.instance(instance_id)

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
          instance = cpi.ec2_resource.instance(instance_id)

          expect(instance.source_dest_check).to be(false)
        end
      end
    end

    context 'with security groups names' do
      let(:security_groups) { get_security_group_names(@subnet_id) }

      it 'can exercise the vm lifecycle' do
        vm_lifecycle
      end
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
            expect(cpi.ec2_resource.instance(instance_id).public_ip_address).to_not be_nil
          end
        end
      end
    end
  end

  def vm_lifecycle(options = {})
    vm_disks = options[:disks] || disks
    ami_id = options[:ami] || ami
    stemcell_id = cpi.create_stemcell('/not/a/real/path', { 'ami' => { @region => ami_id } })
    expect(stemcell_id).to end_with(' light')

    instance_id = cpi.create_vm(
      nil,
      stemcell_id,
      vm_type,
      network_spec,
      vm_disks,
      nil,
    )
    expect(instance_id).not_to be_nil

    expect(cpi.has_vm?(instance_id)).to be(true)

    cpi.set_vm_metadata(instance_id, vm_metadata)

    yield(instance_id) if block_given?
  ensure
    cpi.delete_vm(instance_id) if instance_id
    cpi.delete_stemcell(stemcell_id) if stemcell_id
    expect(get_ami(ami)).to exist
  end

  def get_security_group_ids(subnet_id)
    ec2_client = Aws::EC2::Client.new(
      region:      @region,
      access_key_id: @access_key_id,
      secret_access_key: @secret_access_key,
    )
    ec2 = Aws::EC2::Resource.new(client: ec2_client)

    security_groups = ec2.subnet(subnet_id).vpc.security_groups
    security_groups.map { |sg| sg.id }
  end

  def get_security_group_names(subnet_id)
    ec2_client = Aws::EC2::Client.new(
      credentials: Aws::Credentials.new(@access_key_id, @secret_access_key),
      region:      @region,
    )
    ec2 = Aws::EC2::Resource.new(client: ec2_client)
    security_groups = ec2.subnet(subnet_id).vpc.security_groups
    security_groups.map { |sg| sg.group_name }
  end

  def get_ami(ami_id)
    ec2_client = Aws::EC2::Client.new(
      credentials: Aws::Credentials.new(@access_key_id, @secret_access_key),
      region:      @region,
    )
    ec2 = Aws::EC2::Resource.new(client: ec2_client)
    ec2.image(ami_id)
  end
end

def array_key_value_to_hash(arr_with_keys)
  hash = {}

  arr_with_keys.each do |obj|
    hash[obj.key] = obj.value
  end
  hash
end

class RegisteredInstances < StandardError; end

def ensure_no_instances_registered_with_elb(logger, elb_client, elb_id)
  instances = elb_client.describe_load_balancers({:load_balancer_names => [elb_id]})[:load_balancer_descriptions]
                        .first[:instances]

  logger.debug("we believe instances: #{instances} are attached to elb #{elb_id}")

  if !instances.empty?
    raise RegisteredInstances
  end

  true
end
