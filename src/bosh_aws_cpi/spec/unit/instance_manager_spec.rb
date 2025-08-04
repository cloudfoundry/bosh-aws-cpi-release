require 'spec_helper'

module Bosh::AwsCloud
  describe InstanceManager do
    let(:ec2) { instance_double(Aws::EC2::Resource) }
    let(:aws_client) { instance_double(Aws::EC2::Client) }
    before { allow(ec2).to receive(:client).and_return(aws_client) }

    let(:param_mapper) { instance_double(InstanceParamMapper) }
    let(:instance_manager) { InstanceManager.new(ec2, logger) }
    let(:logger) { Logger.new('/dev/null') }

    let(:settings) { instance_double(Bosh::AwsCloud::AgentSettings) }

    let(:user_data) { { password: 'secret' } }

    describe '#create' do
      let(:fake_aws_subnet) { instance_double(Aws::EC2::Subnet, id: 'sub-123456', availability_zone: 'us-east-1a') }

      let(:aws_instance) { instance_double(Aws::EC2::Instance, id: 'i-12345678') }
      let(:aws_network_interface) { instance_double(Aws::EC2::NetworkInterface) }

      let(:stemcell_id) { 'stemcell-id' }
      let(:vm_type) do
        {
          'instance_type' => 'm1.small',
          'availability_zone' => 'us-east-1a',
        }
      end
      let(:global_config) do
        instance_double(Bosh::AwsCloud::Config, aws: Bosh::AwsCloud::AwsConfig.new(default_options['aws']))
      end
      let(:vm_cloud_props) do
        Bosh::AwsCloud::VMCloudProps.new(vm_type, global_config)
      end
      let(:networks_spec) do
        {
          'default' => {
            'type' => 'dynamic',
            'dns' => 'foo',
            'cloud_properties' => { 'subnet' => 'sub-default', 'security_groups' => 'baz' }
          },
          'other' => {
            'type' => 'manual',
            'cloud_properties' => { 'subnet' => 'sub-123456' },
            'ip' => '1.2.3.4'
          }
        }
      end
      let(:networks_cloud_props) do
        Bosh::AwsCloud::NetworkCloudProps.new(networks_spec, global_config)
      end
      let(:disk_locality) { nil }
      let(:default_options) do
        {
          'aws' => {
            'region' => 'us-east-1',
            'default_key_name' => 'some-key',
            'default_security_groups' => ['baz']
          }
        }
      end
      let(:block_devices) do
        [
          double(
            Aws::EC2::Types::BlockDeviceMapping,
            device_name: 'fake-image-root-device',
            ebs: double(Aws::EC2::Types::EbsBlockDevice, volume_size: 17)
          )
        ]
      end
      let(:fake_block_device_mappings) { 'fake-block-device-mappings' }

      let(:instance) { instance_double(Bosh::AwsCloud::Instance, id: 'fake-instance-id') }
      let(:fake_instance_params) do
        {
          fake: 'instance-params',
          user_data: user_data,
          defaults: {
            access_key_id: 'AWSKEYID',
            secret_access_key: 'AWSSECRET',
          },
        }
      end
      let(:run_instances_params) do
        fake_instance_params.merge(min_count: 1, max_count: 1)
      end
      let(:network_interface) { instance_double(Bosh::AwsCloud::NetworkInterface) }
      let(:fake_network_interface_params) do
        {
          ip_address: 'fake-ip-address'
        }
      end
      let(:tags) { {'tag' => 'tag_value'} }

      before do
        allow(param_mapper).to receive(:instance_params).and_return(fake_instance_params)
        allow(param_mapper).to receive(:network_interface_params).and_return(fake_network_interface_params)
        allow(param_mapper).to receive(:private_ip_addresses)
        allow(param_mapper).to receive(:manifest_params=)
        allow(param_mapper).to receive(:validate)
        allow(param_mapper).to receive(:update_user_data)
        instance_manager.instance_variable_set('@param_mapper', param_mapper)

        allow(ec2).to receive(:subnets).with(
          filters: [{
            name: 'subnet-id',
            values: ['sub-default', 'sub-123456'],
          }],
        ).and_return([fake_aws_subnet])

        # allow(ec2).to receive(:instances).and_return([aws_instance])
        allow(ec2).to receive(:instances)
        allow(ec2).to receive(:image).with(stemcell_id).and_return(
          instance_double(
            Aws::EC2::Image,
            root_device_name: 'fake-image-root-device',
            block_device_mappings: block_devices,
            virtualization_type: :hvm
          )
        )

        allow(ec2).to receive(:instance).with('i-12345678').and_return(aws_instance)
        allow(ec2).to receive(:network_interface).with('fake_network_interface_id').and_return(aws_network_interface)

        allow(Instance).to receive(:new).and_return(instance)
        allow(instance).to receive(:wait_until_exists)
        allow(instance).to receive(:wait_until_running)
        allow(instance).to receive(:update_routing_tables)

        allow(NetworkInterface).to receive(:new).and_return(network_interface)
        allow(network_interface).to receive(:attach_ip_prefixes)
        allow(network_interface).to receive(:wait_until_available)
        allow(network_interface).to receive(:mac_address)
        allow(network_interface).to receive(:nic_configuration)

        allow(settings).to receive(:encode).and_return(user_data)
        allow(settings).to receive(:update_agent_networks_settings)
      end

      context 'when user_data is defined as a parameter' do
        let(:user_data) { {'unicorns' => 'have rainbow hair'} }

        it 'should use user_data when building the instance params' do
          allow(instance_manager).to receive(:get_created_instance_id).and_return('i-12345678')
          allow(instance_manager).to receive(:get_created_network_interface_id).and_return('fake_network_interface_id')
          allow(aws_client).to receive(:run_instances)
          allow(aws_client).to receive(:create_network_interface)

          expect(param_mapper).to receive(:manifest_params=).with(hash_including(user_data: user_data))
          expect(param_mapper).to receive(:update_user_data)

          instance_manager.create(
            stemcell_id,
            vm_cloud_props,
            networks_cloud_props,
            disk_locality,
            default_options,
            fake_block_device_mappings,
            settings,
            tags,
            nil,
            nil
          )
        end

        it 'uses the requested api version to encode agent settings' do
          allow(instance_manager).to receive(:get_created_instance_id).and_return('i-12345678')
          allow(instance_manager).to receive(:get_created_network_interface_id).and_return('fake_network_interface_id')
          allow(aws_client).to receive(:run_instances)
          allow(aws_client).to receive(:create_network_interface)
          expect(settings).to receive(:encode).with('fake_api_version')

          instance_manager.create(
            stemcell_id,
            vm_cloud_props,
            networks_cloud_props,
            disk_locality,
            default_options,
            fake_block_device_mappings,
            settings,
            tags,
            nil,
            'fake_api_version'
          )
        end
      end

      it 'should ask AWS to create an instance in the given region, with parameters built up from the given arguments' do
        allow(instance_manager).to receive(:get_created_instance_id).with('run-instances-response').and_return('i-12345678')
        allow(instance_manager).to receive(:get_created_network_interface_id).and_return('fake_network_interface_id')

        allow(aws_client).to receive(:create_network_interface)

        expect(aws_client).to receive(:run_instances).with(run_instances_params).and_return('run-instances-response')
        instance_manager.create(
          stemcell_id,
          vm_cloud_props,
          networks_cloud_props,
          disk_locality,
          default_options,
          fake_block_device_mappings,
          settings,
          tags,
          nil,
          nil
        )
      end

      it 'passes private_ip_addresses to attach_ip_prefixes' do
        allow(instance_manager).to receive(:get_created_instance_id).with('run-instances-response').and_return('i-12345678')
        allow(aws_client).to receive(:run_instances).with(run_instances_params).and_return('run-instances-response')
        allow(param_mapper).to receive(:private_ip_addresses).and_return(['ip1', 'ip2'])

        expect(instance).to receive(:attach_ip_prefixes).with(instance, ['ip1', 'ip2'])
        instance_manager.create(
          stemcell_id,
          vm_cloud_props,
          networks_cloud_props,
          disk_locality,
          default_options,
          fake_block_device_mappings,
          user_data,
          tags,
          nil
        )
      end

      context 'redacts' do
        before do
          allow(instance_manager).to receive(:get_created_instance_id).and_return('i-12345678')
          allow(instance_manager).to receive(:get_created_network_interface_id).and_return('fake_network_interface_id')

          allow(aws_client).to receive(:run_instances)
          allow(aws_client).to receive(:create_network_interface)

          allow(logger).to receive(:info)
          instance_manager.create(
            stemcell_id,
            vm_cloud_props,
            networks_cloud_props,
            disk_locality,
            default_options,
            fake_block_device_mappings,
            settings,
            tags,
            nil,
            nil
          )
        end

        it '`user_data` when creating an instance' do
          expect(logger).to have_received(:info).with(/"user_data"=>"<redacted>"/)
        end

        it '`defaults.access_key_id` when creating an instance' do
          expect(logger).to have_received(:info).with(/"access_key_id"=>"<redacted>"/)
        end

        it '`defaults.secret_access_key` when creating an instance' do
          expect(logger).to have_received(:info).with(/"secret_access_key"=>"<redacted>"/)
        end
      end

      context 'when spot_bid_price is specified' do
        let(:vm_type) do
          # NB: The spot_bid_price param should trigger spot instance creation
          {'spot_bid_price'=>0.15, 'instance_type' => 'm1.small', 'key_name' => 'bar', 'availability_zone' => 'us-east-1a'}
        end
        let(:request_spot_instances_result) {
          instance_double(Aws::EC2::Types::RequestSpotInstancesResult, spot_instance_requests: spot_instance_requests)
        }
        let(:spot_instance_requests) {
          [
            instance_double(
              Aws::EC2::Types::SpotInstanceRequest,
              spot_instance_request_id: 'sir-12345c',
              state: 'active',
              instance_id: 'i-12345678',
            ),
          ]
        }
        let(:describe_spot_instance_requests_result) {
          instance_double(Aws::EC2::Types::DescribeSpotInstanceRequestsResult, spot_instance_requests: spot_instance_requests)
        }

        it 'should ask AWS to create a SPOT instance in the given region, when vm_type includes spot_bid_price' do
          allow(ec2).to receive(:client).and_return(aws_client)
          allow(instance_manager).to receive(:get_created_network_interface_id).and_return('fake_network_interface_id')
          allow(aws_client).to receive(:create_network_interface)

          # need to translate security group names to security group ids
          sg1 = instance_double('Aws::EC2::SecurityGroup', id:'sg-baz-1234')
          allow(ec2).to receive(:security_groups).and_return([sg1])

          # Should not receive an on-demand instance create call
          expect(aws_client).to_not receive(:run_instances)

          # Should rather receive a spot instance request
          expect(aws_client).to receive(:request_spot_instances) do |spot_request|
            expect(spot_request[:spot_price]).to eq('0.15')
            expect(spot_request[:instance_count]).to eq(1)
            expect(spot_request[:launch_specification]).to eq(fake_instance_params)

            # return
            request_spot_instances_result
          end

          # Should poll the spot instance request until state is active
          expect(aws_client).to receive(:describe_spot_instance_requests).
            with(:spot_instance_request_ids=>['sir-12345c']).
              and_return(describe_spot_instance_requests_result)

          # Trigger spot instance request
          instance_manager.create(
            stemcell_id,
            vm_cloud_props,
            networks_cloud_props,
            disk_locality,
            default_options,
            fake_block_device_mappings,
            settings,
            tags,
            nil,
            nil
          )
        end

        context 'when spot creation fails' do
          it 'raises and logs an error' do
            expect(instance_manager).to receive(:create_aws_spot_instance).and_raise(Bosh::Clouds::VMCreationFailed.new(false))
            allow(instance_manager).to receive(:get_created_network_interface_id).and_return('fake_network_interface_id')
            allow(aws_client).to receive(:create_network_interface)
            expect(logger).to receive(:warn).with(/Spot instance creation failed/)

            expect {
              instance_manager.create(
                stemcell_id,
                vm_cloud_props,
                networks_cloud_props,
                disk_locality,
                default_options,
                fake_block_device_mappings,
                settings,
                tags,
                nil,
                nil
              )
            }.to raise_error(Bosh::Clouds::VMCreationFailed, /Spot instance creation failed/)

          end

          context 'and spot_ondemand_fallback is configured' do
            let(:vm_type) do
              {
                'spot_bid_price' => 0.15,
                'spot_ondemand_fallback' => true,
                'instance_type' => 'm1.small',
                'key_name' => 'bar',
                'availability_zone' => 'us-east-1a'
              }
            end
            let(:message) { 'bid-price-too-low' }

            before do
              allow(instance_manager).to receive(:get_created_network_interface_id).and_return('fake_network_interface_id')
              allow(aws_client).to receive(:create_network_interface)
              allow(aws_client).to receive(:run_instances)
              allow(instance_manager).to receive(:get_created_instance_id).and_return('i-12345678')
              expect(instance_manager).to receive(:create_aws_spot_instance).and_raise(Bosh::Clouds::VMCreationFailed.new(false), message)
            end

            it 'creates an on demand instance' do
              expect(network_interface).to_not receive(:delete)
              expect(aws_client).to receive(:run_instances)
                .with(run_instances_params)

              instance_manager.create(
                stemcell_id,
                vm_cloud_props,
                networks_cloud_props,
                disk_locality,
                default_options,
                fake_block_device_mappings,
                settings,
                tags,
                nil,
                nil
              )
            end

            it 'does not log a warn but logs an info' do
              expect(logger).to_not receive(:warn)
              allow(logger).to receive(:info)
              expect(logger).to receive(:info).exactly(1)
                .with("Spot instance creation failed with this message: #{message}; will create ondemand instance because `spot_ondemand_fallback` is set.")

              instance_manager.create(
                stemcell_id,
                vm_cloud_props,
                networks_cloud_props,
                disk_locality,
                default_options,
                fake_block_device_mappings,
                settings,
                tags,
                nil,
                nil
              )
            end
          end
        end
      end


      context 'when source_dest_check is set to true' do
        it 'does NOT call disable_dest_check' do
          allow(instance_manager).to receive(:get_created_instance_id).with('run-instances-response').and_return('i-12345678')
          allow(instance_manager).to receive(:get_created_network_interface_id).and_return('fake_network_interface_id')

          expect(instance).not_to receive(:disable_dest_check)
          expect(aws_client).to receive(:run_instances).with(run_instances_params).and_return('run-instances-response')
          allow(aws_client).to receive(:create_network_interface)
          expect(instance).to receive(:wait_until_running)

          instance_manager.create(
            stemcell_id,
            vm_cloud_props,
            networks_cloud_props,
            disk_locality,
            default_options,
            fake_block_device_mappings,
            settings,
            tags,
            nil,
            nil
          )
        end
      end

      context 'when source_dest_check is set to false' do
        before do
          vm_type['source_dest_check'] = false
        end

        it 'disables source_dest_check on the instance' do
          allow(instance_manager).to receive(:get_created_instance_id).with('run-instances-response').and_return('i-12345678')
          allow(instance_manager).to receive(:get_created_network_interface_id).and_return('fake_network_interface_id')
          allow(aws_client).to receive(:create_network_interface)

          expect(instance).to receive(:disable_dest_check)
          expect(aws_client).to receive(:run_instances).with(run_instances_params).and_return('run-instances-response')
          expect(instance).to receive(:wait_until_running)

          instance_manager.create(
            stemcell_id,
            vm_cloud_props,
            networks_cloud_props,
            disk_locality,
            default_options,
            fake_block_device_mappings,
            settings,
            tags,
            nil,
            nil
          )
        end
      end

      it 'should retry creating the Network Interface when Aws::EC2::Errors::InvalidIPAddressInUse raised' do
        allow(instance_manager).to receive(:network_interface_create_wait_time).and_return(0)
        allow(instance_manager).to receive(:get_created_instance_id).with('run-instances-response').and_return('i-12345678')
        allow(instance_manager).to receive(:get_created_network_interface_id).and_return('fake_network_interface_id')

        expect(aws_client).to receive(:create_network_interface).
          with(fake_network_interface_params).
          and_raise(Aws::EC2::Errors::InvalidIPAddressInUse.new(nil, 'in-use'))

        expect(aws_client).to receive(:create_network_interface)
          .with(fake_network_interface_params)

        expect(aws_client).to receive(:run_instances).with(run_instances_params).and_return('run-instances-response')

        expect(logger).to receive(:warn).with(/IP address was in use/).once

        instance_manager.create(
          stemcell_id,
          vm_cloud_props,
          networks_cloud_props,
          disk_locality,
          default_options,
          fake_block_device_mappings,
          settings,
          tags,
          nil,
          nil
        )
      end

      context 'when waiting for the instance to be running fails' do
        let(:instance) { instance_double(Bosh::AwsCloud::Instance, id: 'fake-instance-id') }
        let(:create_err) { StandardError.new('fake-err') }

        before { allow(Instance).to receive(:new).and_return(instance) }

        it 'terminates created instance and re-raises the error' do
          allow(instance_manager).to receive(:get_created_instance_id).with('run-instances-response').and_return('i-12345678')
          allow(instance_manager).to receive(:get_created_network_interface_id).and_return('fake_network_interface_id')
          allow(aws_client).to receive(:create_network_interface)

          expect(aws_client).to receive(:run_instances).with(run_instances_params).and_return('run-instances-response')
          expect(instance).to receive(:wait_until_running).and_raise(create_err)

          expect(instance).to receive(:terminate).with(no_args)

          expect {
            instance_manager.create(
              stemcell_id,
              vm_cloud_props,
              networks_cloud_props,
              disk_locality,
              default_options,
              fake_block_device_mappings,
              settings,
              tags,
              nil,
              nil
            )
          }.to raise_error(create_err)
        end

        it 'should retry creating the VM twice then give up when Bosh::Clouds::AbruptlyTerminated is raised' do
          allow(instance_manager).to receive(:get_created_instance_id).with('run-instances-response').and_return('i-12345678')
          allow(instance_manager).to receive(:get_created_network_interface_id).and_return('fake_network_interface_id')

          expect(Instance).to receive(:new).exactly(3).times

          allow(aws_client).to receive(:create_network_interface)
          expect(aws_client).to receive(:run_instances).with(run_instances_params).and_return('run-instances-response').exactly(3).times
          expect(instance).to receive(:wait_until_running).and_raise(Bosh::AwsCloud::AbruptlyTerminated, 'Server.InternalError: Internal error on launch').exactly(3).times
          expect(logger).to receive(:warn).with(/Failed to configure instance 'fake-instance-id'/).exactly(3).times
          expect(logger).to receive(:warn).with(/'fake-instance-id' was abruptly terminated, attempting to re-create/).twice

          expect {
            instance_manager.create(
              stemcell_id,
              vm_cloud_props,
              networks_cloud_props,
              disk_locality,
              default_options,
              fake_block_device_mappings,
              settings,
              tags,
              nil,
              nil
            )
          }.to raise_error(Bosh::AwsCloud::AbruptlyTerminated)
        end

        context 'when termination of created instance fails' do
          before { allow(instance).to receive(:terminate).and_raise(StandardError.new('fake-terminate-err')) }

          it 're-raises creation error' do
            allow(instance_manager).to receive(:get_created_instance_id).with('run-instances-response').and_return('i-12345678')
            allow(instance_manager).to receive(:get_created_network_interface_id).and_return('fake_network_interface_id')
            allow(aws_client).to receive(:create_network_interface)

            expect(aws_client).to receive(:run_instances).with(run_instances_params).and_return('run-instances-response')
            expect(instance).to receive(:wait_until_running).and_raise(create_err)

            expect {
              instance_manager.create(
                stemcell_id,
                vm_cloud_props,
                networks_cloud_props,
                disk_locality,
                default_options,
                fake_block_device_mappings,
                settings,
                tags,
                nil,
                nil
              )
            }.to raise_error(create_err)
          end
        end
      end
    end

    describe '#find' do
      before { allow(ec2).to receive(:instance).with(instance_id).and_return(aws_instance) }
      let(:aws_instance) { instance_double(Aws::EC2::Instance, id: instance_id) }
      let(:instance_id) { 'fake-id' }

      it 'returns found instance (even though it might not exist)' do
        instance = instance_double(Bosh::AwsCloud::Instance)

        allow(Bosh::AwsCloud::Instance).to receive(:new).
          with(aws_instance, logger).
          and_return(instance)

        expect(instance_manager.find(instance_id)).to eq(instance)
      end
    end
  end
end
