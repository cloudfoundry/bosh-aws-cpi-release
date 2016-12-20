require 'spec_helper'
require 'logger'

module Bosh::AwsCloud
  describe Instance do
    subject(:instance) { Instance.new(aws_instance, registry, elb, logger) }
    let(:aws_instance) { instance_double('Aws::EC2::Instance', id: instance_id) }
    let(:registry) { instance_double('Bosh::Cpi::RegistryClient', :update_settings => nil) }
    let(:elb) { double('Aws::ELB') }
    let(:logger) { Logger.new('/dev/null') }

    let(:instance_id) { 'fake-id' }

    describe '#id' do
      it('returns instance id') { expect(instance.id).to eq(instance_id) }
    end

    describe '#elastic_ip' do
      it 'returns elastic IP' do
        expect(aws_instance).to receive(:elastic_ip).and_return('fake-ip')
        expect(instance.elastic_ip).to eq('fake-ip')
      end
    end

    describe '#associate_elastic_ip' do
      it 'propagates associate_elastic_ip' do
        expect(aws_instance).to receive(:associate_elastic_ip).with('fake-new-ip')
        instance.associate_elastic_ip('fake-new-ip')
      end
    end

    describe '#disassociate_elastic_ip' do
      it 'propagates disassociate_elastic_ip' do
        expect(aws_instance).to receive(:disassociate_elastic_ip)
        instance.disassociate_elastic_ip
      end
    end

    describe '#exists?' do
      it 'returns false if instance does not exist' do
        expect(aws_instance).to receive(:exists?).and_return(false)
        expect(instance.exists?).to be(false)
      end

      it 'returns true if instance does exist' do
        expect(aws_instance).to receive(:exists?).and_return(true)
        expect(aws_instance).to receive(:status).and_return(:running)
        expect(instance.exists?).to be(true)
      end

      it 'returns false if instance exists but is terminated' do
        expect(aws_instance).to receive(:exists?).and_return(true)
        expect(aws_instance).to receive(:status).and_return(:terminated)
        expect(instance.exists?).to be(false)
      end
    end

    describe '#wait_for_running' do
      it 'waits for instance state to be running' do
        expect(ResourceWait).to receive(:for_instance).with(
          instance: aws_instance,
          state: :running,
        )
        instance.wait_for_running
      end

      context 'when the operation times out' do
        it 'raises and logs an error' do
          expect(ResourceWait).to receive(:for_instance)
            .and_raise(Bosh::Common::RetryCountExceeded)

          expect(logger).to receive(:warn).with(/Timed out waiting for instance/)
          expect {
            instance.wait_for_running
          }.to raise_error(Bosh::Clouds::VMCreationFailed, /Timed out waiting for instance/)
        end
      end
    end

    describe '#terminate' do
      it 'should terminate an instance given the id' do
        allow(instance).to receive(:remove_from_load_balancers).ordered
        expect(aws_instance).to receive(:terminate).with(no_args).ordered
        expect(registry).to receive(:delete_settings).with(instance_id).ordered

        expect(ResourceWait).to receive(:for_instance).
          with(instance: aws_instance, state: :terminated).ordered

        instance.terminate
      end

      context 'when instance was deleted in AWS and no longer exists (showing in AWS console)' do
        before do
          # AWS returns NotFound error if instance no longer exists in AWS console
          # (This could happen when instance was deleted manually and BOSH is not aware of that)
          allow(aws_instance).to receive(:terminate).
            with(no_args).and_raise(Aws::EC2::Errors::InvalidInstanceIDNotFound)
        end

        it 'raises Bosh::Clouds::VMNotFound but still removes settings from registry' do
          expect(registry).to receive(:delete_settings).with(instance_id)

          expect {
            instance.terminate
          }.to raise_error(Bosh::Clouds::VMNotFound, "VM `#{instance_id}' not found")
        end
      end

      context 'when instance is already terminated when bosh checks for the state' do
        before do
          # AWS returns NotFound error if instance no longer exists in AWS console
          # (This could happen when instance was deleted very quickly and BOSH didn't catch the terminated state)
          allow(aws_instance).to receive(:terminate).with(no_args).ordered
        end

        it 'logs a message and considers the instance to be terminated' do
          expect(registry).to receive(:delete_settings).with(instance_id)

          allow(aws_instance).to receive(:status).
                                     with(no_args).and_raise(Aws::EC2::Errors::InvalidInstanceIDNotFound)

          expect(logger).to receive(:debug).with("Failed to find terminated instance '#{instance_id}' after deletion: #{Aws::EC2::Errors::InvalidInstanceIDNotFound.new.inspect}")

          instance.terminate
        end
      end

      describe 'fast path deletion' do
        it 'deletes the instance without waiting for confirmation of termination' do
          allow(aws_instance).to receive(:terminate).ordered
          allow(registry).to receive(:delete_settings).ordered
          expect(TagManager).to receive(:tag).with(aws_instance, "Name", "to be deleted").ordered
          instance.terminate(true)
        end
      end
    end

    describe '#reboot' do
      it 'reboots the instance' do
        expect(aws_instance).to receive(:reboot).with(no_args)
        instance.reboot
      end
    end

    describe '#update_routing_tables' do
      let(:fake_vpc) { instance_double('Aws::EC2::VPC') }
      let(:fake_tables) { instance_double('Aws::EC2::RouteTableCollection') }
      let(:fake_table) { instance_double('Aws::EC2::RouteTable') }
      let(:fake_route) { instance_double('Aws::EC2::Route') }
      let(:fake_routes) {[ fake_route ]}

      before do
        allow(aws_instance).to receive(:vpc).and_return(fake_vpc)
        allow(fake_vpc).to receive(:route_tables).and_return(fake_tables)
        allow(fake_tables).to receive(:[]).with('r-12345').and_return(fake_table)
        allow(fake_table).to receive(:routes).and_return(fake_routes)
        allow(fake_route).to receive(:destination_cidr_block).and_return("10.0.0.0/16")
      end
      it 'updates the routing table entry with the instance ID when finding an existing route' do
          destination = "10.0.0.0/16"
          expect(fake_table).to receive(:replace_route).with(destination, { :instance => aws_instance })
          instance.update_routing_tables [{ "table_id" => "r-12345", "destination" => destination }]
      end
      it 'creates a routing table entry with the instance ID when the route does not exist' do
          destination = "10.5.0.0/16"
          expect(fake_table).to receive(:create_route).with(destination, { :instance => aws_instance })
          instance.update_routing_tables [{ "table_id" => "r-12345", "destination" => destination }]
      end
    end

    describe '#source_dest_check=' do
      it 'propagates source_dest_check= true' do
        expect(aws_instance).to receive(:source_dest_check=).with(false)
        instance.source_dest_check = false
      end

      it 'propagates source_dest_check= false' do
        expect(aws_instance).to receive(:source_dest_check=).with(true)
        instance.source_dest_check = true
      end
    end

    describe '#attach_to_load_balancers' do
      before { allow(elb).to receive(:load_balancers).and_return(load_balancers) }
      let(:load_balancers) { { 'fake-lb1-id' => load_balancer1, 'fake-lb2-id' => load_balancer2 } }
      let(:load_balancer1) { instance_double('Aws::ELB::LoadBalancer', instances: lb1_instances) }
      let(:lb1_instances) { instance_double('Aws::ELB::InstanceCollection') }
      let(:load_balancer2) { instance_double('Aws::ELB::LoadBalancer', instances: lb2_instances) }
      let(:lb2_instances) { instance_double('Aws::ELB::InstanceCollection') }

      it 'attaches the instance to the list of load balancers' do
        expect(lb1_instances).to receive(:register).with(aws_instance)
        expect(lb2_instances).to receive(:register).with(aws_instance)
        instance.attach_to_load_balancers(%w(fake-lb1-id fake-lb2-id))
      end
    end
  end
end
