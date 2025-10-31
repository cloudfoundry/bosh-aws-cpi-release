require 'spec_helper'

module Bosh::AwsCloud
  describe NetworkInterfaceManager do
    let(:ec2_resource) { instance_double(Aws::EC2::Resource) }
    let(:ec2_client) { instance_double(Aws::EC2::Client)}
    let(:network_interface_manager) { NetworkInterfaceManager.new(ec2_resource, logger) }
    let(:logger) { Logger.new('/dev/null') }
    let(:aws_network_interface) { instance_double(Aws::EC2::NetworkInterface)}
    let(:network_interface) { instance_double(Bosh::AwsCloud::NetworkInterface)}
    let(:create_network_interface_response) { instance_double(Aws::EC2::Types::CreateNetworkInterfaceResult)}

    before do
      allow(Bosh::AwsCloud::NetworkInterface).to receive(:new).with(aws_network_interface, ec2_client, logger).and_return(network_interface)
      allow(create_network_interface_response).to receive(:network_interface).and_return(aws_network_interface)
    end


    describe '#initialize' do
      it 'initializes with ec2 resource and logger' do
        manager = NetworkInterfaceManager.new(ec2_resource, logger)

        expect(manager.instance_variable_get(:@ec2_resource)).to eq(ec2_resource)
        expect(manager.instance_variable_get(:@logger)).to eq(logger)
      end
    end

    describe '#create_network_interfaces' do
      let(:vm_cloud_props) { instance_double(Bosh::AwsCloud::VMCloudProps) }
      let(:security_group_mapper) { instance_double(Bosh::AwsCloud::SecurityGroupMapper) }
      let(:default_security_groups) { ['sg-default'] }
      let(:manual_network_spec) do
        {
          'net1' => {
            'type' => 'manual',
            'ip' => '10.0.0.1',
            'cloud_properties' => { 'subnet' => 'manual_subnet_id' }
          }
        }
      end

      let(:networks_cloud_props) { Bosh::AwsCloud::NetworkCloudProps.new(manual_network_spec, nil) }
      let(:expected_create_ni_params) do
        {
          subnet_id: 'manual_subnet_id',
          private_ip_address: '10.0.0.1',
          groups: default_security_groups
        }
      end

      context 'when everything is set up correctly' do
        before do
          allow(Bosh::AwsCloud::SecurityGroupMapper).to receive(:new).and_return(security_group_mapper)
          allow(ec2_resource).to receive(:subnets).and_return([])
          allow(ec2_resource).to receive(:client).and_return(ec2_client)
          allow(ec2_resource).to receive(:network_interface).with('eni-12345678').and_return(aws_network_interface)
          allow(vm_cloud_props).to receive(:security_groups).and_return('')
          allow(security_group_mapper).to receive(:map_to_ids).and_return(default_security_groups)

          allow(aws_network_interface).to receive(:network_interface_id).and_return('eni-12345678')

          expect(network_interface).to receive(:wait_until_available)
          expect(network_interface).to receive(:add_associate_public_ip_address)
          expect(network_interface).to receive(:mac_address)
        end

        it 'creates one network interface if one network is defined' do
          expect(ec2_client).to receive(:create_network_interface).with(expected_create_ni_params).and_return(create_network_interface_response)

          network_interfaces = nil
          expect {
            network_interfaces = network_interface_manager.create_network_interfaces(networks_cloud_props, vm_cloud_props, default_security_groups)
          }.not_to raise_error

          expect(network_interfaces).to be_an(Array)
          expect(network_interfaces.size).to eq(1)
          expect(network_interfaces.first).to eq(network_interface)
        end

        it 'retries the creation of one network interface if one network is defined and the address is currently in use' do
          allow(network_interface_manager).to receive(:network_interface_create_wait_time).and_return(0)

          return_values = [:raise, create_network_interface_response]

          expect(ec2_client).to receive(:create_network_interface).with(expected_create_ni_params).exactly(2).times do
            return_value = return_values.shift
            return_value == :raise ? raise(Aws::EC2::Errors::InvalidIPAddressInUse.new(nil, 'IP address is already in use')) : return_value
          end

          network_interfaces = nil
          expect {
            network_interfaces = network_interface_manager.create_network_interfaces(networks_cloud_props, vm_cloud_props, default_security_groups)
          }.not_to raise_error

          expect(network_interfaces).to be_an(Array)
          expect(network_interfaces.size).to eq(1)
          expect(network_interfaces.first).to eq(network_interface)
        end

        context 'when two networks with similar nic_groups are provided'  do
          let(:expected_create_ni_params) do
            {
              groups: default_security_groups,
              subnet_id: 'manual_subnet_id',
              ipv_6_addresses: [{
                ipv_6_address: '2001:db8::1'
              }],
              private_ip_address: '10.0.0.1',
            }
          end

          let(:manual_network_spec) do
            {
              'net1' => {
                'type' => 'manual',
                'ip' => '10.0.0.1',
                'cloud_properties' => { 'subnet' => 'manual_subnet_id' },
                'nic_group' => '1'
              },
              'net2' => {
                'type' => 'manual',
                'ip' => '2001:db8::1',
                'cloud_properties' => { 'subnet' => 'manual_subnet_id' },
                'nic_group' => '1'
              },
            }
          end

          it 'creates one network interface with two ip addresses' do
            expect(ec2_client).to receive(:create_network_interface).with(expected_create_ni_params).and_return(create_network_interface_response)

            network_interfaces = nil
            expect {
              network_interfaces = network_interface_manager.create_network_interfaces(networks_cloud_props, vm_cloud_props, default_security_groups)
            }.not_to raise_error

            expect(network_interfaces).to be_an(Array)
            expect(network_interfaces.size).to eq(1)
            expect(network_interfaces.first).to eq(network_interface)
          end
        end

        context 'when two networks with same ip version and similar nic_groups are provided'  do
          let(:manual_network_spec) do
            {
              'net1' => {
                'type' => 'manual',
                'ip' => '10.0.0.1',
                'cloud_properties' => { 'subnet' => 'manual_subnet_id' },
                'nic_group' => '1'
              },
              'net2' => {
                'type' => 'manual',
                'ip' => '10.0.0.2',
                'cloud_properties' => { 'subnet' => 'manual_subnet_id' },
                'nic_group' => '1'
              },
            }
          end

          it 'creates one network interface with one ip address' do
            expect(ec2_client).to receive(:create_network_interface).with(expected_create_ni_params).and_return(create_network_interface_response)

            network_interfaces = nil
            expect {
              network_interfaces = network_interface_manager.create_network_interfaces(networks_cloud_props, vm_cloud_props, default_security_groups)
            }.not_to raise_error

            expect(network_interfaces).to be_an(Array)
            expect(network_interfaces.size).to eq(1)
            expect(network_interfaces.first).to eq(network_interface)
          end
        end

        context 'when two networks with different nic_groups are provided'  do
          let(:expected_create_ni_params_1) do
            {
              groups: default_security_groups,
              subnet_id: 'manual_subnet_id',
              private_ip_address: '10.0.0.1',
            }
          end
          let(:expected_create_ni_params_2) do
            {
              groups: default_security_groups,
              subnet_id: 'manual_subnet_id',
              private_ip_address: '10.0.0.2',
            }
          end

          let(:manual_network_spec) do
            {
              'net1' => {
                'type' => 'manual',
                'ip' => '10.0.0.1',
                'cloud_properties' => { 'subnet' => 'manual_subnet_id' },
                'nic_group' => '1'
              },
              'net2' => {
                'type' => 'manual',
                'ip' => '10.0.0.2',
                'cloud_properties' => { 'subnet' => 'manual_subnet_id' },
                'nic_group' => '2'
              },
            }
          end

          it 'creates two network interface with one ip address each' do
            allow(aws_network_interface).to receive(:network_interface_id).and_return('eni-87654321')
            allow(ec2_resource).to receive(:network_interface).with('eni-87654321').and_return(aws_network_interface)

            expect(network_interface).to receive(:wait_until_available)
            expect(network_interface).to receive(:add_associate_public_ip_address)
            expect(network_interface).to receive(:mac_address)

            expect(ec2_client).to receive(:create_network_interface).with(expected_create_ni_params_1).and_return(create_network_interface_response)
            expect(ec2_client).to receive(:create_network_interface).with(expected_create_ni_params_2).and_return(create_network_interface_response)

            network_interfaces = nil
            expect {
              network_interfaces = network_interface_manager.create_network_interfaces(networks_cloud_props, vm_cloud_props, default_security_groups)
            }.not_to raise_error

            expect(network_interfaces).to be_an(Array)
            expect(network_interfaces.size).to eq(2)
            expect(network_interfaces).to eq([network_interface, network_interface])
          end
        end

        context 'when a prefix is defined'  do
          let(:expected_create_ni_params_1) do
            {
              groups: default_security_groups,
              subnet_id: 'manual_subnet_id',
              private_ip_address: '10.0.0.1',
            }
          end

          let(:manual_network_spec) do
            {
              'net1' => {
                'type' => 'manual',
                'ip' => '10.0.0.1',
                'cloud_properties' => { 'subnet' => 'manual_subnet_id' },
                'nic_group' => '1',
              },
              'net2' => {
                'type' => 'manual',
                'ip' => '10.0.0.2',
                'cloud_properties' => { 'subnet' => 'manual_subnet_id' },
                'nic_group' => '1',
                'prefix' => '24'
              },
            }
          end

          it 'creates one network interface and attaches the prefix after creation' do
            allow(aws_network_interface).to receive(:network_interface_id).and_return('eni-12345678', 'eni-87654321')
            allow(ec2_resource).to receive(:network_interface).with('eni-87654321').and_return(aws_network_interface)

            expect(network_interface).to receive(:attach_ip_prefixes)

            expect(ec2_client).to receive(:create_network_interface).with(expected_create_ni_params_1).and_return(create_network_interface_response)

            network_interfaces = nil
            expect {
              network_interfaces = network_interface_manager.create_network_interfaces(networks_cloud_props, vm_cloud_props, default_security_groups)
            }.not_to raise_error

            expect(network_interfaces).to be_an(Array)
            expect(network_interfaces.size).to eq(1)
            expect(network_interfaces).to eq([network_interface])
          end
        end
      end

      context 'when something is not set up correctly' do
        before do
          allow(Bosh::AwsCloud::SecurityGroupMapper).to receive(:new).and_return(security_group_mapper)
          allow(network_interface_manager).to receive(:network_interface_create_wait_time).and_return(0)
        end

        context 'when a prefix network is not a secondary network' do
          let(:manual_network_spec) do
            {
              'net1' => {
                'type' => 'manual',
                'ip' => '10.0.0.1',
                'cloud_properties' => { 'subnet' => 'manual_subnet_id' },
                'nic_group' => '1',
                'prefix' => '24'
              },
            }
          end
          it 'receives an error from validate_and_extract_ip_config' do
            expect {
              network_interface_manager.create_network_interfaces(networks_cloud_props, vm_cloud_props, default_security_groups)
            }.to raise_error(Bosh::Clouds::CloudError, /Could not find a single ip address for nic group '1' and a prefix network can only be a secondary network./)
          end
        end

        context 'when aws keeps constantly reporting that the address is currently in use' do
          it 'does not create a network interface and aborts' do
            allow(ec2_resource).to receive(:subnets).and_return([])
            allow(ec2_resource).to receive(:client).and_return(ec2_client)
            allow(vm_cloud_props).to receive(:security_groups).and_return('')
            allow(security_group_mapper).to receive(:map_to_ids).and_return(default_security_groups)

            expect(ec2_client).to receive(:create_network_interface).with(expected_create_ni_params).exactly(20).times.and_raise(Aws::EC2::Errors::InvalidIPAddressInUse.new(nil, 'IP address is already in use'))

            expect(network_interface).to_not receive(:wait_until_available)
            expect(network_interface).to_not receive(:add_associate_public_ip_address)
            expect(network_interface).to_not receive(:mac_address)
            expect {
              network_interface_manager.create_network_interfaces(networks_cloud_props, vm_cloud_props, default_security_groups)
            }.to raise_error(Bosh::Clouds::CloudError, "Failed to create network interface for nic_group 'net1': IP address is already in use")
          end
        end

        context 'when some error happens after some network interfaces have already been created' do
          let(:expected_create_ni_params_1) do
            {
              groups: default_security_groups,
              subnet_id: 'manual_subnet_id',
              private_ip_address: '10.0.0.1',
            }
          end

          let(:expected_create_ni_params_2) do
            {
              groups: default_security_groups,
              subnet_id: 'manual_subnet_id',
              ipv_6_addresses: [{
                ipv_6_address: '2001:db8::1'
              }]
            }
          end

          let(:manual_network_spec) do
            {
              'net1' => {
                'type' => 'manual',
                'ip' => '10.0.0.1',
                'cloud_properties' => { 'subnet' => 'manual_subnet_id' },
                'nic_group' => '1'
              },
              'net2' => {
                'type' => 'manual',
                'ip' => '2001:db8::1',
                'cloud_properties' => { 'subnet' => 'manual_subnet_id' },
                'nic_group' => '2'
              },
              'net3' => {
                'type' => 'manual',
                'ip' => '2001:db8::2',
                'cloud_properties' => { 'subnet' => 'manual_subnet_id' },
                'nic_group' => '2',
                'prefix' => '80'
              },
            }
          end

          it 'deletes the network interfaces that have already been created and raises an error' do
            allow(Bosh::AwsCloud::SecurityGroupMapper).to receive(:new).and_return(security_group_mapper)
            allow(ec2_resource).to receive(:subnets).and_return([])
            allow(ec2_resource).to receive(:client).and_return(ec2_client)
            allow(ec2_resource).to receive(:network_interface).with('eni-12345678').and_return(aws_network_interface)
            allow(vm_cloud_props).to receive(:security_groups).and_return('')
            allow(security_group_mapper).to receive(:map_to_ids).and_return(default_security_groups)
            allow(Bosh::AwsCloud::NetworkInterface).to receive(:new).with(aws_network_interface, ec2_client, logger).and_return(network_interface)
            allow(create_network_interface_response).to receive(:network_interface).and_return(aws_network_interface)
            allow(aws_network_interface).to receive(:network_interface_id).and_return('eni-12345678')
            allow(network_interface).to receive(:attach_ip_prefixes).and_raise(Bosh::Clouds::CloudError, 'Some error happened while attaching prefixes')

            expect(network_interface).to receive(:wait_until_available).twice
            expect(network_interface).to receive(:add_associate_public_ip_address)
            expect(network_interface).to receive(:mac_address)
            expect(network_interface).to receive(:delete).twice

            expect(ec2_client).to receive(:create_network_interface).with(expected_create_ni_params_1).and_return(create_network_interface_response)
            expect(ec2_client).to receive(:create_network_interface).with(expected_create_ni_params_2).and_return(create_network_interface_response)

            expect {
              network_interface_manager.create_network_interfaces(networks_cloud_props, vm_cloud_props, default_security_groups)
            }.to raise_error(Bosh::Clouds::CloudError, "Failed to create network interface for nic_group '2': Some error happened while attaching prefixes")
          end
        end
      end
    end

    describe '#set_delete_on_termination_for_network_interfaces' do
      let(:describe_nic_result) { instance_double(Aws::EC2::Types::DescribeNetworkInterfacesResult) }
      let(:network_interface_2) { instance_double(Bosh::AwsCloud::NetworkInterface) }
      let(:network_interface_type_1) { instance_double(Aws::EC2::Types::NetworkInterface) }
      let(:network_interface_type_2) { instance_double(Aws::EC2::Types::NetworkInterface) }
      let(:bosh_nic_attachment1) { instance_double(Aws::EC2::Types::NetworkInterfaceAttachment) }
      let(:bosh_nic_attachment2) { instance_double(Aws::EC2::Types::NetworkInterfaceAttachment) }

      before do
        allow(network_interface_2).to receive(:id).and_return('eni-67890')
        allow(network_interface).to receive(:id).and_return('eni-12345')

        allow(ec2_resource).to receive(:client).and_return(ec2_client)
      end

      it 'calls modify_network_interface_attribute to set delete_on_termination to true' do
        allow(ec2_client).to receive(:describe_network_interfaces).with({
          network_interface_ids: ['eni-12345', 'eni-67890']
        }).and_return(describe_nic_result)

        allow(describe_nic_result).to receive(:network_interfaces).and_return([network_interface_type_1, network_interface_type_2])

        allow(network_interface_type_1).to receive(:attachment).and_return(bosh_nic_attachment1)
        allow(network_interface_type_2).to receive(:attachment).and_return(bosh_nic_attachment2)

        allow(network_interface_type_1).to receive(:network_interface_id).and_return('eni-12345')
        allow(network_interface_type_2).to receive(:network_interface_id).and_return('eni-67890')

        allow(bosh_nic_attachment1).to receive(:attachment_id).and_return('attach-11111')
        allow(bosh_nic_attachment2).to receive(:attachment_id).and_return('attach-22222')


        expect(ec2_client).to receive(:modify_network_interface_attribute).with({
          network_interface_id: 'eni-12345',
          attachment: {
            attachment_id: 'attach-11111',
            delete_on_termination: true
            }
            })
        expect(ec2_client).to receive(:modify_network_interface_attribute).with({
          network_interface_id: 'eni-67890',
          attachment: {
            attachment_id: 'attach-22222',
            delete_on_termination: true
            }
            })

        network_interface_manager.set_delete_on_termination_for_network_interfaces([network_interface, network_interface_2])
      end


      it 'raises an error if a network interface is not attached' do
        allow(ec2_client).to receive(:describe_network_interfaces).with({
          network_interface_ids: ['eni-12345']
        }).and_return(describe_nic_result)

        allow(describe_nic_result).to receive(:network_interfaces).and_return([network_interface_type_1])
        allow(network_interface_type_1).to receive(:attachment).and_return(nil)
        allow(network_interface_type_1).to receive(:network_interface_id).and_return('eni-12345')

        expect {
          network_interface_manager.set_delete_on_termination_for_network_interfaces([network_interface])
        }.to raise_error(Bosh::Clouds::CloudError, /Network interface 'eni-12345' is not attached to any instance/)
      end
    end

    describe '#delete_network_interfaces' do
      it 'deletes the provided network interfaces' do
        mock_bosh_ni1 = instance_double(Bosh::AwsCloud::NetworkInterface)
        mock_bosh_ni2 = instance_double(Bosh::AwsCloud::NetworkInterface)

        expect(mock_bosh_ni1).to receive(:delete)
        expect(mock_bosh_ni2).to receive(:delete)

        network_interface_manager.delete_network_interfaces([mock_bosh_ni1, mock_bosh_ni2])
      end
    end
  end
end