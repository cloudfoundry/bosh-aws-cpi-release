require 'spec_helper'

module Bosh::AwsCloud
  describe InstanceManager do
    let(:ec2) { instance_double(Aws::EC2::Resource) }
    let(:aws_client) { instance_double(Aws::EC2::Client) }
    before { allow(ec2).to receive(:client).and_return(aws_client) }

    let(:registry) { double('Bosh::Registry::Client', :endpoint => 'http://...', :update_settings => nil) }
    let(:elb) { instance_double(Aws::ElasticLoadBalancing::Client) }
    let(:param_mapper) { instance_double(InstanceParamMapper) }
    let(:block_device_manager) { instance_double(BlockDeviceManager) }
    let(:logger) { Logger.new('/dev/null') }

    describe '#create' do
      let(:fake_subnet_collection) { instance_double('Aws::EC2::SubnetCollection')}
      let(:fake_availability_zone) { instance_double('Aws::EC2::AvailabilityZone', name: 'us-east-1a')}
      let(:fake_aws_subnet) { instance_double('Aws::EC2::Subnet', id: 'sub-123456', availability_zone: fake_availability_zone) }

      let(:aws_instances) { instance_double('Aws::EC2::InstanceCollection') }
      let(:aws_instance) { instance_double('Aws::EC2::Instance', id: 'i-12345678') }

      let(:agent_id) { 'agent-id' }
      let(:stemcell_id) { 'stemcell-id' }
      let(:vm_type) { {
        'instance_type' => 'm1.small',
        'availability_zone' => 'us-east-1a',
      } }
      let(:networks_spec) do
        {
          'default' => {
            'type' => 'dynamic',
            'dns' => 'foo',
            'cloud_properties' => {'subnet' => 'sub-default', 'security_groups' => 'baz'}
          },
          'other' => {
            'type' => 'manual',
            'cloud_properties' => {'subnet' => 'sub-123456'},
            'ip' => '1.2.3.4'
          }
        }
      end
      let(:disk_locality) { nil }
      let(:environment) { nil }
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
          double(Aws::AutoScaling::Types::BlockDeviceMapping,
            device_name: 'fake-image-root-device',
            ebs: double(Aws::AutoScaling::Types::Ebs,
              volume_size: 17
            )
          )
        ]
      end

      let(:instance) { instance_double('Bosh::AwsCloud::Instance', id: 'fake-instance-id') }

      before do
        allow(param_mapper).to receive(:instance_params).and_return({ fake: 'instance-params' })
        allow(param_mapper).to receive(:manifest_params=)
        allow(param_mapper).to receive(:validate)
        allow(block_device_manager).to receive(:vm_type=)
        allow(block_device_manager).to receive(:virtualization_type=)
        allow(block_device_manager).to receive(:root_device_name=)
        allow(block_device_manager).to receive(:ami_block_device_names=)
        allow(block_device_manager).to receive(:mappings).and_return('fake-block-device-mappings')
        allow(block_device_manager).to receive(:agent_info).and_return('fake-block-device-agent-info')

        allow(ResourceWait).to receive(:for_instance).with(instance: aws_instance, state: 'running')

        allow(ec2).to receive(:subnets).with({
          filters: [{
            name: 'subnet-id',
            values: ['sub-default', 'sub-123456'],
          }],
        }).and_return([fake_aws_subnet])

        allow(ec2).to receive(:instances).and_return(aws_instances)
        allow(ec2).to receive(:image).with(stemcell_id).and_return(
          instance_double('Aws::EC2::Image',
            root_device_name: 'fake-image-root-device',
            block_device_mappings: block_devices,
            virtualization_type: :hvm
          )
        )

        allow(ec2).to receive(:instance).with('i-12345678').and_return(aws_instance)

        allow(Instance).to receive(:new).and_return(instance)
        allow(instance).to receive(:wait_for_running)
        allow(instance).to receive(:attach_to_load_balancers)
        allow(instance).to receive(:update_routing_tables)
      end

      it 'should ask AWS to create an instance in the given region, with parameters built up from the given arguments' do
        instance_manager = InstanceManager.new(ec2, registry, elb, param_mapper, block_device_manager, logger)
        allow(instance_manager).to receive(:get_created_instance_id).with("run-instances-response").and_return('i-12345678')

        expect(aws_client).to receive(:run_instances).with({ fake: 'instance-params', min_count: 1, max_count: 1 }).and_return("run-instances-response")
        instance_manager.create(
          agent_id,
          stemcell_id,
          vm_type,
          networks_spec,
          disk_locality,
          environment,
          default_options
        )
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

          # need to translate security group names to security group ids
          sg1 = instance_double('Aws::EC2::SecurityGroup', id:'sg-baz-1234')
          allow(ec2).to receive(:security_groups).and_return([sg1])

          # Should not receive an on-demand instance create call
          expect(aws_client).to_not receive(:run_instances)

          # Should rather receive a spot instance request
          expect(aws_client).to receive(:request_spot_instances) do |spot_request|
            expect(spot_request[:spot_price]).to eq('0.15')
            expect(spot_request[:instance_count]).to eq(1)
            expect(spot_request[:launch_specification]).to eq({ fake: 'instance-params' })

            # return
            request_spot_instances_result
          end

          # Should poll the spot instance request until state is active
          expect(aws_client).to receive(:describe_spot_instance_requests).
            with(:spot_instance_request_ids=>['sir-12345c']).
              and_return(describe_spot_instance_requests_result)

          # Trigger spot instance request
          instance_manager = InstanceManager.new(ec2, registry, elb, param_mapper, block_device_manager, logger)
          instance_manager.create(
            agent_id,
            stemcell_id,
            vm_type,
            networks_spec,
            disk_locality,
            environment,
            default_options
          )
        end

        context 'when spot creation fails' do
          it 'raises and logs an error' do
            instance_manager = InstanceManager.new(ec2, registry, elb, param_mapper, block_device_manager, logger)
            expect(instance_manager).to receive(:create_aws_spot_instance).and_raise(Bosh::Clouds::VMCreationFailed.new(false))
            expect(logger).to receive(:warn).with(/Spot instance creation failed/)

            expect {
              instance_manager.create(
                agent_id,
                stemcell_id,
                vm_type,
                networks_spec,
                disk_locality,
                environment,
                default_options
              )
            }.to raise_error(Bosh::Clouds::VMCreationFailed, /Spot instance creation failed/)

          end

          context 'and spot_ondemand_fallback is configured' do
            let(:instance_manager) { InstanceManager.new(ec2, registry, elb, param_mapper, block_device_manager, logger) }
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
              allow(aws_client).to receive(:run_instances)
              allow(instance_manager).to receive(:get_created_instance_id).and_return('i-12345678')
              expect(instance_manager).to receive(:create_aws_spot_instance).and_raise(Bosh::Clouds::VMCreationFailed.new(false), message)
            end

            it 'creates an on demand instance' do
              expect(aws_client).to receive(:run_instances)
                .with({ fake: 'instance-params', min_count: 1, max_count: 1 })

              instance_manager.create(
                agent_id,
                stemcell_id,
                vm_type,
                networks_spec,
                disk_locality,
                environment,
                default_options
              )
            end

            it 'does not log a warn but logs an info' do
              expect(logger).to_not receive(:warn)
              allow(logger).to receive(:info)
              expect(logger).to receive(:info).exactly(1)
                .with("Spot instance creation failed with this message: #{message}; will create ondemand instance because `spot_ondemand_fallback` is set.")

              instance_manager.create(
                agent_id,
                stemcell_id,
                vm_type,
                networks_spec,
                disk_locality,
                environment,
                default_options
              )
            end
          end
        end
      end

      context 'when source_dest_check is set to false' do
        before do
          vm_type['source_dest_check'] = false
        end
        it 'disables source_dest_check on the instance' do
          instance_manager = InstanceManager.new(ec2, registry, elb, param_mapper, block_device_manager, logger)
          allow(instance_manager).to receive(:get_created_instance_id).with("run-instances-response").and_return('i-12345678')

          expect(aws_client).to receive(:run_instances).with({ fake: 'instance-params', min_count: 1, max_count: 1 }).and_return("run-instances-response")
          expect(instance).to receive(:source_dest_check=).with(false)
          expect(instance).to receive(:wait_for_running)
          expect(instance).to receive(:attach_to_load_balancers)
          expect(instance).to receive(:update_routing_tables)

          instance_manager.create(
            agent_id,
            stemcell_id,
            vm_type,
            networks_spec,
            disk_locality,
            environment,
            default_options
          )
        end
      end

      it 'should retry creating the VM when Aws::EC2::Errors::InvalidIPAddressInUse raised' do
        instance_manager = InstanceManager.new(ec2, registry, elb, param_mapper, block_device_manager, logger)
        allow(instance_manager).to receive(:instance_create_wait_time).and_return(0)
        allow(instance_manager).to receive(:get_created_instance_id).with('run-instances-response').and_return('i-12345678')

        expect(aws_client).to receive(:run_instances).with({ fake: 'instance-params', min_count: 1, max_count: 1 }).and_raise(Aws::EC2::Errors::InvalidIPAddressInUse.new(nil, 'in-use'))
        expect(aws_client).to receive(:run_instances).with({ fake: 'instance-params', min_count: 1, max_count: 1 }).and_return("run-instances-response")

        allow(ResourceWait).to receive(:for_instance).with(instance: aws_instance, state: :running)
        expect(logger).to receive(:warn).with(/IP address was in use/).once

        instance_manager.create(
          agent_id,
          stemcell_id,
          vm_type,
          networks_spec,
          disk_locality,
          environment,
          default_options
        )
      end

      context 'when waiting for the instance to be running fails' do
        let(:instance) { instance_double('Bosh::AwsCloud::Instance', id: 'fake-instance-id') }
        let(:create_err) { StandardError.new('fake-err') }

        before { allow(Instance).to receive(:new).and_return(instance) }

        it 'terminates created instance and re-raises the error' do
          instance_manager = InstanceManager.new(ec2, registry, elb, param_mapper, block_device_manager, logger)
          allow(instance_manager).to receive(:get_created_instance_id).with("run-instances-response").and_return('i-12345678')

          expect(aws_client).to receive(:run_instances).with({ fake: 'instance-params', min_count: 1, max_count: 1 }).and_return("run-instances-response")
          expect(instance).to receive(:wait_for_running).and_raise(create_err)

          expect(instance).to receive(:terminate).with(no_args)

          expect {
            instance_manager.create(
              agent_id,
              stemcell_id,
              vm_type,
              networks_spec,
              disk_locality,
              environment,
              default_options
            )
          }.to raise_error(create_err)
        end

        context 'when termination of created instance fails' do
          before { allow(instance).to receive(:terminate).and_raise(StandardError.new('fake-terminate-err')) }

          it 're-raises creation error' do
            instance_manager = InstanceManager.new(ec2, registry, elb, param_mapper, block_device_manager, logger)
            allow(instance_manager).to receive(:get_created_instance_id).with("run-instances-response").and_return('i-12345678')

            expect(aws_client).to receive(:run_instances).with({ fake: 'instance-params', min_count: 1, max_count: 1 }).and_return("run-instances-response")
            expect(instance).to receive(:wait_for_running).and_raise(create_err)

            expect {
              instance_manager.create(
                agent_id,
                stemcell_id,
                vm_type,
                networks_spec,
                disk_locality,
                environment,
                default_options
              )
            }.to raise_error(create_err)
          end
        end
      end

      context 'when attaching instance to load balancers fails' do
        let(:instance) { instance_double('Bosh::AwsCloud::Instance', id: 'fake-instance-id', wait_for_running: nil) }
        let(:lb_err) { StandardError.new('fake-err') }

        before { allow(Instance).to receive(:new).and_return(instance) }

        it 'terminates created instance and re-raises the error' do
          instance_manager = InstanceManager.new(ec2, registry, elb, param_mapper, block_device_manager, logger)
          allow(instance_manager).to receive(:get_created_instance_id).with("run-instances-response").and_return('i-12345678')

          expect(aws_client).to receive(:run_instances).with({ fake: 'instance-params', min_count: 1, max_count: 1 }).and_return("run-instances-response")
          expect(instance).to receive(:attach_to_load_balancers).and_raise(lb_err)

          expect(instance).to receive(:terminate).with(no_args)

          expect {
            instance_manager.create(
              agent_id,
              stemcell_id,
              vm_type,
              networks_spec,
              disk_locality,
              environment,
              default_options
            )
          }.to raise_error(lb_err)
        end

        context 'when termination of created instance fails' do
          before { allow(instance).to receive(:terminate).and_raise(StandardError.new('fake-terminate-err')) }

          it 're-raises creation error' do
            instance_manager = InstanceManager.new(ec2, registry, elb, param_mapper, block_device_manager, logger)
            allow(instance_manager).to receive(:get_created_instance_id).with("run-instances-response").and_return('i-12345678')

            expect(aws_client).to receive(:run_instances).with({ fake: 'instance-params', min_count: 1, max_count: 1 }).and_return("run-instances-response")
            expect(instance).to receive(:attach_to_load_balancers).and_raise(lb_err)

            expect {
              instance_manager.create(
                agent_id,
                stemcell_id,
                vm_type,
                networks_spec,
                disk_locality,
                environment,
                default_options
              )
            }.to raise_error(lb_err)
          end
        end
      end
    end

    describe '#find' do
      before { allow(ec2).to receive(:instance).with(instance_id).and_return(aws_instance) }
      let(:aws_instance) { instance_double('Aws::EC2::Instance', id: instance_id) }
      let(:instance_id) { 'fake-id' }

      it 'returns found instance (even though it might not exist)' do
        instance = instance_double('Bosh::AwsCloud::Instance')

        allow(Instance).to receive(:new).
          with(aws_instance, registry, elb, logger).
          and_return(instance)

        instance_manager = InstanceManager.new(ec2, registry, elb, param_mapper, block_device_manager, logger)
        expect(instance_manager.find(instance_id)).to eq(instance)
      end
    end
  end
end
