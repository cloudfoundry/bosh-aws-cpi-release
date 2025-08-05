require 'spec_helper'
require 'logger'

module Bosh::AwsCloud
  describe Instance do
    subject(:instance) { Instance.new(aws_instance, logger) }
    let(:aws_instance) { instance_double(Aws::EC2::Instance, id: instance_id, data: 'some-data') }
    let(:logger) { Logger.new('/dev/null') }
    let(:elastic_ip) { instance_double(Aws::EC2::VpcAddress, public_ip: 'fake-ip') }
    let(:instance_id) { 'fake-id' }

    describe '#id' do
      it('returns instance id') { expect(instance.id).to eq(instance_id) }
    end

    describe '#elastic_ip' do
      it 'returns elastic IP' do
        expect(aws_instance).to receive(:vpc_addresses).and_return([elastic_ip])
        expect(instance.elastic_ip).to eq('fake-ip')
      end
    end

    describe '#associate_elastic_ip' do
      it 'propagates associate_elastic_ip' do
        new_ip = instance_double(Aws::EC2::VpcAddress, public_ip: 'fake-ip')
        expect(Aws::EC2::VpcAddress).to receive(:new).with('fake-new-ip').and_return(new_ip)
        expect(new_ip).to receive(:associate).with(instance_id: instance_id)

        instance.associate_elastic_ip('fake-new-ip')
      end
    end

    describe '#disassociate_elastic_ip' do
      it 'propagates disassociate_elastic_ip' do
        expect(aws_instance).to receive(:vpc_addresses).and_return([elastic_ip])
        expect(elastic_ip).to receive_message_chain("association.delete")
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
        expect(aws_instance).to receive_message_chain('state.name').and_return('running')
        expect(instance.exists?).to be(true)
      end

      it 'returns false if instance exists but is terminated' do
        expect(aws_instance).to receive(:exists?).and_return(true)
        expect(aws_instance).to receive_message_chain('state.name').and_return('terminated')
        expect(instance.exists?).to be(false)
      end
    end

    describe '#wait_until_exists' do
      let(:aws_updated_instance) { instance_double(Aws::EC2::Instance, id: 'same-id', data: 'data-with-reservation') }

      it 'waits for instance to exist' do
        expect(aws_instance).to receive(:wait_until_exists).and_return(aws_updated_instance)
        instance.wait_until_exists
        expect(instance.id).to eq('same-id')
      end

      context 'when the operation times out' do
        it 'raises and logs an error' do
          expect(aws_instance).to receive(:wait_until_exists)
            .and_raise(Aws::Waiters::Errors::TooManyAttemptsError.new(1))

          expect(logger).to receive(:warn).with(/Timed out waiting for instance '#{instance_id}' to exist/)
          expect {
            instance.wait_until_exists
          }.to raise_error(Bosh::Clouds::VMCreationFailed, /Timed out waiting for instance '#{instance_id}' to exist/)
        end
      end
    end

    describe '#wait_until_running' do
      let(:aws_updated_instance) { instance_double(Aws::EC2::Instance, id: 'same-id', data: 'data-with-reservation') }

      it 'waits for the instance to be running' do
        expect(aws_instance).to receive(:wait_until_running).and_return(aws_updated_instance)
        instance.wait_until_running
        expect(instance.id).to eq('same-id')
      end

      context 'when the operation times out' do
        it 'raises and logs an error' do
          expect(aws_instance).to receive(:wait_until_running)
            .and_raise(Aws::Waiters::Errors::TooManyAttemptsError.new(1))

          expect(logger).to receive(:warn).with(/Timed out waiting for instance/)
          expect {
            instance.wait_until_running
          }.to raise_error(Bosh::Clouds::VMCreationFailed, /Timed out waiting for instance/)
        end
      end
    end

    describe '#terminate' do
      it 'should terminate an instance given the id' do
        expect(aws_instance).to receive(:terminate).with(no_args).ordered
        expect(aws_instance).to receive(:wait_until_terminated).ordered

        instance.terminate
      end

      context 'when instance was deleted in AWS and no longer exists (showing in AWS console)' do
        before do
          # AWS returns NotFound error if instance no longer exists in AWS console
          # (This could happen when instance was deleted manually and BOSH is not aware of that)
          allow(aws_instance).to receive(:terminate).
            with(no_args).and_raise(Aws::EC2::Errors::InvalidInstanceIDNotFound.new(nil, 'not-found'))
        end

        it 'raises Bosh::Clouds::VMNotFound but still removes settings from registry' do
          expect {
            instance.terminate
          }.to raise_error(Bosh::Clouds::VMNotFound, "VM `#{instance_id}' not found")
        end
      end

      context 'when instance is already terminated when bosh checks for the state' do
        it 'logs a message and considers the instance to be terminated' do
          # AWS returns NotFound error if instance no longer exists in AWS console
          # (This could happen when instance was deleted very quickly and BOSH didn't catch the terminated state)
          expect(aws_instance).to receive(:terminate).with(no_args).ordered

          err = Aws::EC2::Errors::InvalidInstanceIDNotFound.new(nil, 'not-found')
          expect(aws_instance).to receive(:wait_until_terminated).with(no_args).ordered.and_raise(err)
          expect(logger).to receive(:debug).with("Failed to find terminated instance '#{instance_id}' after deletion: #{err.inspect}")

          instance.terminate
        end
      end

      describe 'fast path deletion' do
        it 'deletes the instance without waiting for confirmation of termination' do
          expect(aws_instance).to receive(:terminate).ordered
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
      let(:fake_vpc) { instance_double(Aws::EC2::Vpc) }
      let(:fake_route_table) { instance_double(Aws::EC2::RouteTable, route_table_id: 'r-12345', id: 'r-12345') }
      let(:fake_route_table_type) { instance_double(Aws::EC2::Types::RouteTable, route_table_id: 'r-12345') }
      let(:fake_route_type) { instance_double(Aws::EC2::Types::Route) }
      let(:fake_routes) {[ fake_route_type ]}
      let(:fake_route) { instance_double(Aws::EC2::Route) }

      before do
        allow(aws_instance).to receive(:vpc).and_return(fake_vpc)
        allow(fake_vpc).to receive(:route_tables).and_return([fake_route_table])
        allow(fake_route_table).to receive(:data).and_return(fake_route_table_type)
        allow(fake_route_table).to receive(:client)
        allow(fake_route_table_type).to receive(:routes).and_return(fake_routes)
        allow(fake_route_type).to receive(:destination_cidr_block).and_return("10.0.0.0/16")
        allow(Aws::EC2::Route).to receive(:new).and_return(fake_route)
      end

      it 'updates the routing table entry with the instance ID when finding an existing route' do
        destination = "10.0.0.0/16"
        expect(fake_route).to receive(:replace).with(instance_id: instance_id)
        instance.update_routing_tables [Bosh::AwsCloud::VMCloudProps::AdvertisedRoute.new(
          "table_id" => "r-12345", "destination" => destination
        )]
      end

      it 'creates a routing table entry with the instance ID when the route does not exist' do
        destination = "10.5.0.0/16"
        expect(fake_route_table).to receive(:create_route).with(destination_cidr_block: destination, instance_id: instance_id)
        instance.update_routing_tables [Bosh::AwsCloud::VMCloudProps::AdvertisedRoute.new(
          "table_id" => "r-12345", "destination" => destination
        )]
      end
    end

    describe '#disable_dest_check' do
      it 'sets source_dest_check attribute to false' do
        expect(aws_instance).to receive(:modify_attribute).with(source_dest_check: {value: false})
        instance.disable_dest_check
      end
    end

    describe '#network_interface_id' do
      it 'returns the network interface id of the first network interface' do
        network_interface = instance_double(Aws::EC2::NetworkInterface, network_interface_id: 'eni-12345')
        allow(aws_instance).to receive(:network_interfaces).and_return([network_interface])
        expect(instance.network_interface_id).to eq('eni-12345')
      end
    end

    describe '#attach_ip_prefixes' do
      let(:network_interface_id) { 'eni-12345' }
      let(:private_ip_addresses) do
        [
          { ip: '10.0.0.1', prefix: 28 },
          { ip: '2001:db8::1', prefix: 80 }
        ]
      end
      let(:ec2_client) { double('Aws::EC2::Client') }
      let(:ec2) { double('Aws::EC2', client: ec2_client) }
      let(:instance_obj) { instance }

      before do
        allow(instance_obj).to receive(:network_interface_id).and_return(network_interface_id)
        instance.instance_variable_set(:@ec2, ec2)
      end

      it 'assigns IPv4 and IPv6 prefixes when prefix is within valid range' do
        expect(ec2_client).to receive(:assign_private_ip_addresses).with(
          network_interface_id: network_interface_id,
          ipv_4_prefixes: ['10.0.0.1/28']
        )
        allow(instance_obj).to receive(:ipv6_address?).and_return(false, true)
        expect(ec2_client).to receive(:assign_ipv_6_addresses).with(
          network_interface_id: network_interface_id,
          ipv_6_prefixes: ['2001:db8::1/80']
        )
        instance_obj.attach_ip_prefixes(instance_obj, private_ip_addresses)
      end

      it 'does not assign prefixes if prefix is empty or too large' do
        addresses = [
          { ip: '10.0.0.2', prefix: '' },
          { ip: '10.0.0.3', prefix: 33 },
          { ip: '2001:db8::2', prefix: '' },
          { ip: '2001:db8::3', prefix: 129 }
        ]
        allow(instance_obj).to receive(:ipv6_address?).and_return(false, false, true, true)
        expect(ec2_client).not_to receive(:assign_private_ip_addresses)
        expect(ec2_client).not_to receive(:assign_ipv_6_addresses)
        instance_obj.attach_ip_prefixes(instance_obj, addresses)
      end
    end
  end
end
