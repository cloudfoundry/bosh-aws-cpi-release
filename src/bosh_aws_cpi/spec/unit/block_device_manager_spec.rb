require 'spec_helper'

module Bosh::AwsCloud
  describe 'BlockDeviceManager' do
    let(:logger) { Logger.new('/dev/null') }
    let(:default_root) do
      {
        device_name: default_root_dev,
        ebs: {
          volume_type: 'gp2',
          delete_on_termination: true,
        },
      }
    end
    let(:default_root_dev) { '/dev/xvda' }
    let(:aws_config) do
      instance_double(Bosh::AwsCloud::AwsConfig)
    end
    let(:global_config) { instance_double(Bosh::AwsCloud::Config, aws: aws_config) }
    let(:vm_type) do
      {
        'key_name' => 'bar',
        'availability_zone' => 'us-east-1a',
        'instance_type' => 'm3.xlarge',
        'raw_instance_storage' => false
      }
    end
    let(:vm_cloud_props) do
      Bosh::AwsCloud::VMCloudProps.new(vm_type, global_config)
    end

    let(:image_id) { 'ami-1234567' }
    let(:image) { instance_double(Aws::EC2::Image, id: image_id) }
    let(:stemcell) { instance_double(Bosh::AwsCloud::Stemcell, ami: image, image_id: image_id) }

    let(:virtualization_type) { 'hvm' }
    let(:root_device_name) { '/dev/xvda' }
    let(:original_block_device_mappings) { [] }
    let(:snapshot) { nil }

    let(:manager) { BlockDeviceManager.new(logger, stemcell, vm_cloud_props, snapshot) }

    before do
      allow(aws_config).to receive(:default_iam_instance_profile)
      allow(aws_config).to receive(:encrypted)
      allow(aws_config).to receive(:kms_key_arn)

      allow(image).to receive(:virtualization_type).and_return(virtualization_type)
      allow(image).to receive(:root_device_name).and_return(root_device_name)
      allow(image).to receive(:block_device_mappings).and_return(original_block_device_mappings)
    end

    describe '#mappings_and_info' do
      context 'when omitting the ephemeral disk' do
        context 'when instance type has instance storage' do
          let(:instance_type) { 'm3.xlarge' }
          let(:vm_type) do
            {
              'key_name' => 'bar',
              'availability_zone' => 'us-east-1a',
              'instance_type' => instance_type,
              'raw_instance_storage' => raw_instance_storage
            }
          end

          context 'when raw_instance_storage is false' do
            let(:raw_instance_storage) { false }
            it 'returns an ebs volume with size determined by the instance_type' do
              actual_output, agent_info = manager.mappings_and_info
              expected_output = [
                {
                  device_name: '/dev/sdb',
                  ebs: {
                    volume_size: 40,
                    volume_type: 'gp2',
                    delete_on_termination: true,
                  }
                },
                default_root,
              ]
              expect(actual_output).to eq(expected_output)
              expect(agent_info).to eq('ephemeral' => [{'path' => '/dev/sdb'}])
            end
          end

          context 'when raw_instance_storage is true' do
            let(:raw_instance_storage) { true }

            it 'returns an ebs volume with size 10GB and disks for each instance storage disk' do
              actual_output, agent_info = manager.mappings_and_info
              expected_output = [default_root]
              instance_storage_disks = [
                {
                  virtual_name: 'ephemeral0',
                  device_name: '/dev/xvdba'
                },
                {
                  virtual_name: 'ephemeral1',
                  device_name: '/dev/xvdbb'
                }
              ]
              expected_output += instance_storage_disks

              ebs_disk = {
                device_name: '/dev/sdb',
                ebs: {
                  volume_size: 10,
                  volume_type: 'gp2',
                  delete_on_termination: true,
                }
              }
              expected_output << ebs_disk
              expect(actual_output).to match_array(expected_output)
              expect(agent_info).to eq(
                'ephemeral' => [{'path' => '/dev/sdb'}],
                'raw_ephemeral' => [{'path' => '/dev/xvdba'}, {'path' => '/dev/xvdbb'}]
              )
            end

            context 'and NVMe storage types' do
              let(:instance_type) { 'i3.4xlarge' }

              it 'returns an ebs volume with size 10GB and NO disks NVMe instance storage' do
                actual_output, agent_info = manager.mappings_and_info
                expected_output = [default_root]
                instance_storage_disks = []
                expected_output += instance_storage_disks

                ebs_disk = {
                  device_name: '/dev/sdb',
                  ebs: {
                    volume_size: 10,
                    volume_type: 'gp2',
                    delete_on_termination: true,
                  }
                }
                expected_output << ebs_disk
                expect(actual_output).to match_array(expected_output)
                expect(agent_info).to eq(
                  'ephemeral' => [{'path' => '/dev/sdb'}],
                  'raw_ephemeral' => [{'path' => '/dev/nvme0n1'}, {'path' => '/dev/nvme1n1'}],
                )
              end
            end

            context 'when the instance is paravirtual' do
              let(:default_root_dev) { '/dev/sda' }
              let(:virtualization_type) { 'paravirtual' }

              it 'attaches instance disks under /dev/sd[c-z]' do
                actual_output, _agent_info = manager.mappings_and_info
                expected_output = [default_root]
                instance_storage_disks = [
                  {
                    virtual_name: 'ephemeral0',
                    device_name: '/dev/sdc'
                  },
                  {
                    virtual_name: 'ephemeral1',
                    device_name: '/dev/sdd'
                  }
                ]
                expected_output += instance_storage_disks

                ebs_disk = {
                  device_name: '/dev/sdb',
                  ebs: {
                    volume_size: 10,
                    volume_type: 'gp2',
                    delete_on_termination: true,
                  }
                }
                expected_output << ebs_disk
                expect(actual_output).to match_array(expected_output)
              end
            end
          end
        end

        context 'when instance type does not have instance storage' do
          let(:vm_type) do
            {
              'key_name' => 'bar',
              'availability_zone' => 'us-east-1a',
              'instance_type' => 't2.small'
            }
          end

          it 'uses a default 10GB ebs storage for ephemeral disk' do
            mappings, agent_info = manager.mappings_and_info
            ebs_disk = {
              device_name: '/dev/sdb',
              ebs: {
                volume_size: 10,
                volume_type: 'gp2',
                delete_on_termination: true,
              }
            }
            expect(mappings).to contain_exactly(ebs_disk, default_root)
            expect(agent_info).to eq('ephemeral' => [{'path' => '/dev/sdb'}])
          end

          context 'when asked for raw instance storage' do
            let(:vm_type) do
              {
                'key_name' => 'bar',
                'availability_zone' => 'us-east-1a',
                'instance_type' => 't2.small',
                'raw_instance_storage' => true
              }
            end

            it 'raises an error when asked for raw instance storage' do
              expect { manager.mappings_and_info }.to raise_error(
                Bosh::Clouds::CloudError,
                "raw_instance_storage requested for instance type 't2.small' that does not have instance storage"
              )
            end
          end
        end
      end

      context 'when specifying the ephemeral disk size' do
        let(:vm_type) do
          {
            'key_name' => 'bar',
            'availability_zone' => 'us-east-1a',
            'instance_type' => 'm3.xlarge',
            'raw_instance_storage' => false,
            'ephemeral_disk' => {
              'size' => 4000
            }
          }
        end

        it 'returns an ebs with the specified ephemeral disk size' do
          manager = BlockDeviceManager.new(logger, stemcell, vm_cloud_props, nil)

          expected_output = [
            {
              device_name: '/dev/sdb',
              ebs: {
                volume_size: 4,
                volume_type: 'gp2',
                delete_on_termination: true,
              },
            },
            default_root,
          ]

          mappings, _agent_info = manager.mappings_and_info
          expect(mappings).to match_array(expected_output)
        end

        context 'when raw_instance_storage is true' do
          let(:vm_type) do
            {
              'key_name' => 'bar',
              'availability_zone' => 'us-east-1a',
              # this instance type has 2 instance storage disks
              'instance_type' => 'm3.xlarge',
              'raw_instance_storage' => true,
              'ephemeral_disk' => {
                'size' => 4000
              }
            }
          end

          it 'returns disks for new ebs volume and instance storage disks' do
            expected_disks = [
              default_root,
              {
                virtual_name: 'ephemeral0',
                device_name: '/dev/xvdba',
              },
              {
                virtual_name: 'ephemeral1',
                device_name: '/dev/xvdbb',
              },
              {
                device_name: '/dev/sdb',
                ebs: {
                  volume_size: 4,
                  volume_type: 'gp2',
                  delete_on_termination: true,
                }
              }
            ]

            mappings, _agent_info = manager.mappings_and_info
            expect(mappings).to match_array(expected_disks)
          end

          context 'when the instance is paravirtual' do
            let(:default_root_dev) { '/dev/sda' }
            let(:vm_type) do
              {
                'key_name' => 'bar',
                'availability_zone' => 'us-east-1a',
                'instance_type' => 'm3.xlarge',
                'raw_instance_storage' => true,
                'ephemeral_disk' => {
                  'size' => 4000
                }
              }
            end
            let(:virtualization_type) { 'paravirtual' }

            it 'returns disks for new ebs volume and instance storage disks under /dev/sd[c-z]' do
              expected_disks = [
                default_root,
                {
                  virtual_name: 'ephemeral0',
                  device_name: '/dev/sdc'
                },
                {
                  virtual_name: 'ephemeral1',
                  device_name: '/dev/sdd',
                },
                {
                  device_name: '/dev/sdb',
                  ebs: {
                    volume_size: 4,
                    volume_type: 'gp2',
                    delete_on_termination: true,
                  }
                }
              ]

              mappings, _agent_info = manager.mappings_and_info
              expect(mappings).to match_array(expected_disks)
            end
          end
        end
      end

      context 'when specifying the ephemeral disk type' do
        let(:vm_type) do
          {
            'key_name' => 'bar',
            'availability_zone' => 'us-east-1a',
            'instance_type' => 't2.small',
            'ephemeral_disk' => ephemeral_disk
          }
        end
        let(:ephemeral_disk) do
          {
            'type' => 'gp2'
          }
        end

        it 'uses the specified type' do
          ebs_disk = {
            device_name: '/dev/sdb',
            ebs: {
              volume_size: 10,
              volume_type: 'gp2',
              delete_on_termination: true
            }
          }
          mappings, _agent_info = manager.mappings_and_info
          expect(mappings).to contain_exactly(ebs_disk, default_root)
        end

        context 'when type is io1' do
          let(:ephemeral_disk) do
            {
              'type' => 'io1',
              'iops' => 123
            }
          end

          it 'configures the io1 disk' do
            ebs_disk = {
              device_name: '/dev/sdb',
              ebs: {
                volume_size: 10,
                volume_type: 'io1',
                iops: 123,
                delete_on_termination: true
              }
            }
            mappings, _agent_info = manager.mappings_and_info
            expect(mappings).to  contain_exactly(ebs_disk, default_root)
          end
        end
      end

      context 'when specifying encrypted' do
        let(:vm_type) do
          {
            'key_name' => 'bar',
            'availability_zone' => 'us-east-1a',
            'instance_type' => 't2.small',
            'ephemeral_disk' => {
              'size' => 4000,
              'encrypted' => true
            }
          }
        end

        it 'will add it to the ebs configuration' do
          expected_output = [
            {
              device_name: '/dev/sdb',
              ebs: {
                volume_size: 4,
                volume_type: 'gp2',
                delete_on_termination: true,
                encrypted: true
              }
            },
            default_root
          ]

          mappings, _agent_info = manager.mappings_and_info
          expect(mappings).to  match_array(expected_output)
        end

        context 'and kms_key_arn' do
          let(:vm_type) do
            {
              'key_name' => 'bar',
              'availability_zone' => 'us-east-1a',
              'instance_type' => 't2.small',
              'ephemeral_disk' => {
                'size' => 4000,
                'encrypted' => true,
                'kms_key_arn' => 'arn:aws:kms:us-east-1:XXXXXX:key/e1c1f008-779b-4ebe-8116-0a34b77747dd'
              }
            }
          end
          let(:volume) { instance_double(Aws::EC2::Volume) }

          context 'when snapshot is included' do
            let(:snapshot) do
              instance_double(
                Aws::EC2::Snapshot,
                id: 'snap-05e3175b7fc6cce4c',
                exists?: true,
                state: 'completed'
              )
            end

            it 'will add snapshot snapshot_id to the ebs conbfiguration' do
              expected_output = [
                {
                  device_name: '/dev/sdb',
                  ebs: {
                    volume_size: 4,
                    volume_type: 'gp2',
                    delete_on_termination: true,
                    snapshot_id: 'snap-05e3175b7fc6cce4c'
                  }
                },
                default_root
              ]

              mappings, _agent_info = manager.mappings_and_info
              expect(mappings).to  match_array(expected_output)
            end
          end
        end
      end

      context 'when specifying use_instance_storage' do
        context 'when the instance_type has instance storage' do
          let(:vm_type) do
            {
              'key_name' => 'bar',
              'availability_zone' => 'us-east-1a',
              'instance_type' => 'm3.xlarge',
              'ephemeral_disk' => {
                'use_instance_storage' => true
              }
            }
          end

          it 'returns instance storage disks as ephemeral disk' do
            expected_disks = [
              {
                virtual_name: 'ephemeral0',
                device_name: '/dev/sdb'
              },
              default_root
            ]

            mappings, _agent_info = manager.mappings_and_info
            expect(mappings).to  match_array(expected_disks)
          end
        end

        context 'when the instance_type has NO instance storage' do
          let(:vm_type) do
            {
              'key_name' => 'bar',
              'availability_zone' => 'us-east-1a',
              'instance_type' => 't2.small',
              'ephemeral_disk' => {
                'use_instance_storage' => true
              }
            }
          end

          it 'raises an error' do
            expect { manager.mappings_and_info }.to raise_error(
              Bosh::Clouds::CloudError,
              "use_instance_storage requested for instance type 't2.small' that does not have instance storage"
            )
          end
        end

        context 'when any other properties are set for ephemeral_disk' do
          let(:vm_type) do
            {
              'key_name' => 'bar',
              'availability_zone' => 'us-east-1a',
              'instance_type' => 'm3.medium',
              'ephemeral_disk' => {
                'use_instance_storage' => true,
                'size' => 512
              }
            }
          end

          it 'raises an error' do
            expect { manager.mappings_and_info }.to raise_error(
              Bosh::Clouds::CloudError,
              "use_instance_storage cannot be combined with additional ephemeral_disk properties"
            )
          end
        end

        context 'when raw_instance_storage is also set' do
          let(:vm_type) do
            {
              'key_name' => 'bar',
              'availability_zone' => 'us-east-1a',
              'instance_type' => 'm3.medium',
              'ephemeral_disk' => {
                'use_instance_storage' => true
              },
              'raw_instance_storage' => true
            }
          end

          it 'raises an error' do
            expect { manager.mappings_and_info }.to raise_error(
              Bosh::Clouds::CloudError,
              "ephemeral_disk.use_instance_storage and raw_instance_storage cannot both be true"
            )
          end
        end
      end

      context 'when root disk is specified' do
        let(:vm_type) do
          {
            'key_name' => 'bar',
            'availability_zone' => 'us-east-1a',
            'instance_type' => 'm3.medium',
            'root_disk' => {
              'size' => 42 * 1024.0
            }
          }
        end

        it 'should default root disk type to gp2 if type is not specified' do
          mappings, agent_info = manager.mappings_and_info

          expected_disks = [
            {
              device_name: '/dev/xvda',
              ebs: {
                volume_size: 42,
                volume_type: 'gp2',
                delete_on_termination: true
              }
            },
            {
              device_name: '/dev/sdb',
              ebs: {
                volume_size: 4,
                volume_type: 'gp2',
                delete_on_termination: true
              }
            }
          ]

          expect(agent_info).to eq('ephemeral' => [{'path' => '/dev/sdb'}])
          expect(mappings).to match_array(expected_disks)
        end

        context 'when root disk type is io1' do
          let(:vm_type) do
            {
              'key_name' => 'bar',
              'availability_zone' => 'us-east-1a',
              'instance_type' => 'm3.medium',
              'root_disk' => {
                'size' => 42 * 1024.0
              }
            }
          end

          it 'should create disk type of io1 with iops' do
            vm_type['root_disk']['type'] = 'io1'
            vm_type['root_disk']['iops'] = 1000

            manager = BlockDeviceManager.new(logger, stemcell, vm_cloud_props, nil)
            expected_disks = []

            ephemeral_disks = [{
                                 device_name: '/dev/sdb',
                                 ebs: {
                                   volume_size: 4,
                                   volume_type: 'gp2',
                                   delete_on_termination: true,
                                 }
                               }]
            expected_disks += ephemeral_disks

            root_disk = {
              device_name: '/dev/xvda',
              ebs: {
                volume_size: 42,
                volume_type: 'io1',
                iops: 1000,
                delete_on_termination: true,
              }
            }
            expected_disks << root_disk

            actual_disks, _agent_info = manager.mappings_and_info
            expect(actual_disks).to match_array(expected_disks)
          end
        end

        context 'when virtualization_type is not hvm' do
          let(:virtualization_type) { 'paravirtual' }
          it 'should set device name' do
            expected_disks = []

            ephemeral_disks = [{
              device_name: '/dev/sdb',
              ebs: {
                volume_size: 4,
                volume_type: 'gp2',
                delete_on_termination: true,
              }
            }]
            expected_disks += ephemeral_disks

            root_disk = {
              device_name: '/dev/sda',
              ebs: {
                volume_size: 42,
                volume_type: 'gp2',
                delete_on_termination: true,
              }
            }
            expected_disks << root_disk

            actual_disks, _agent_info = manager.mappings_and_info
            expect(actual_disks).to match_array(expected_disks)
          end
        end
      end
    end
  end
end
