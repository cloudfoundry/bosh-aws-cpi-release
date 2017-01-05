require 'spec_helper'

module Bosh::AwsCloud
  describe 'BlockDeviceManager' do
    let(:logger) { Logger.new('/dev/null') }
    let(:default_root) {
      {
        device_name: default_root_dev,
        ebs: {
          volume_type: 'gp2',
          delete_on_termination: true,
        },
      }
    }
    let(:default_root_dev) { '/dev/xvda' }


    describe '#mappings' do

      context 'when omitting the ephemeral disk' do

        context 'when instance type has instance storage' do
          context 'when raw_instance_storage is false' do
            it 'returns an ebs volume with size determined by the instance_type' do
              manager = BlockDeviceManager.new(logger)
              manager.vm_type = {
                'key_name' => 'bar',
                'availability_zone' => 'us-east-1a',
                'instance_type' => 'm3.xlarge',
                'raw_instance_storage' => false
              }

              actual_output = manager.mappings
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
            end
          end

          context 'when raw_instance_storage is true' do
            it 'returns an ebs volume with size 10GB and disks for each instance storage disk' do
              manager = BlockDeviceManager.new(logger)
              manager.vm_type = {
                'key_name' => 'bar',
                'availability_zone' => 'us-east-1a',
                'instance_type' => 'm3.xlarge',
                'raw_instance_storage' => true
              }

              actual_output = manager.mappings
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
            end

            context 'when the instance is paravirtual' do
              let(:default_root_dev) { '/dev/sda' }
              it 'attaches instance disks under /dev/sd[c-z]' do
                manager = BlockDeviceManager.new(logger)
                manager.vm_type = {
                  'key_name' => 'bar',
                  'availability_zone' => 'us-east-1a',
                  'instance_type' => 'm3.xlarge',
                  'raw_instance_storage' => true
                }
                manager.virtualization_type = 'paravirtual'

                actual_output = manager.mappings
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
          it 'uses a default 10GB ebs storage for ephemeral disk' do
            manager = BlockDeviceManager.new(logger)
            manager.vm_type = {
              'key_name' => 'bar',
              'availability_zone' => 'us-east-1a',
              'instance_type' => 't2.small'
            }

            ebs_disk = {
              device_name: '/dev/sdb',
              ebs: {
                volume_size: 10,
                volume_type: 'gp2',
                delete_on_termination: true,
              }
            }
            expect(manager.mappings).to contain_exactly(ebs_disk, default_root)
          end

          it 'raises an error when asked for raw instance storage' do
            manager = BlockDeviceManager.new(logger)
            manager.vm_type = {
              'key_name' => 'bar',
              'availability_zone' => 'us-east-1a',
              'instance_type' => 't2.small',
              'raw_instance_storage' => true
            }
            expect { manager.mappings }.to raise_error(
                                             Bosh::Clouds::CloudError,
                                             "raw_instance_storage requested for instance type 't2.small' that does not have instance storage"
                                           )
          end
        end
      end

      context 'when specifying the ephemeral disk size' do
        it 'returns an ebs with the specified ephemeral disk size' do
          manager = BlockDeviceManager.new(logger)
          manager.vm_type = {
            'key_name' => 'bar',
            'availability_zone' => 'us-east-1a',
            'instance_type' => 'm3.xlarge',
            'raw_instance_storage' => false,
            'ephemeral_disk' => {
              'size' => 4000
            }
          }

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
          expect(manager.mappings).to match_array(expected_output)
        end

        context 'when raw_instance_storage is true' do
          it 'returns disks for new ebs volume and instance storage disks' do
            manager = BlockDeviceManager.new(logger)
            manager.vm_type = {
              'key_name' => 'bar',
              'availability_zone' => 'us-east-1a',
              # this instance type has 2 instance storage disks
              'instance_type' => 'm3.xlarge',
              'raw_instance_storage' => true,
              'ephemeral_disk' => {
                'size' => 4000
              }
            }

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

            expect(manager.mappings).to match_array(expected_disks)
          end

          context 'when the instance is paravirtual' do
            let(:default_root_dev) { '/dev/sda' }
            it 'returns disks for new ebs volume and instance storage disks under /dev/sd[c-z]' do
              manager = BlockDeviceManager.new(logger)
              manager.vm_type = {
                'key_name' => 'bar',
                'availability_zone' => 'us-east-1a',
                'instance_type' => 'm3.xlarge',
                'raw_instance_storage' => true,
                'ephemeral_disk' => {
                  'size' => 4000
                }
              }
              manager.virtualization_type = 'paravirtual'

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

              expect(manager.mappings).to match_array(expected_disks)
            end
          end
        end
      end

      context 'when specifying the ephemeral disk type' do
        it 'uses the specified type' do
          manager = BlockDeviceManager.new(logger)
          manager.vm_type = {
            'key_name' => 'bar',
            'availability_zone' => 'us-east-1a',
            'instance_type' => 't2.small',
            'ephemeral_disk' => {
              'type' => 'gp2'
            }
          }

          ebs_disk = {
            device_name: '/dev/sdb',
            ebs: {
              volume_size: 10,
              volume_type: 'gp2',
              delete_on_termination: true,
            }
          }
          expect(manager.mappings).to contain_exactly(ebs_disk, default_root)
        end

        context 'when type is io1' do
          it 'configures the io1 disk' do
            manager = BlockDeviceManager.new(logger)
            manager.vm_type = {
              'key_name' => 'bar',
              'availability_zone' => 'us-east-1a',
              'instance_type' => 't2.small',
              'ephemeral_disk' => {
                'type' => 'io1',
                'iops' => 123
              }
            }

            ebs_disk = {
              device_name: '/dev/sdb',
              ebs: {
                volume_size: 10,
                volume_type: 'io1',
                iops: 123,
                delete_on_termination: true,
              }
            }
            expect(manager.mappings).to contain_exactly(ebs_disk, default_root)
          end
        end
      end

      context 'when specifying encrypted' do
        it 'will add it to the ebs configuration' do
          manager = BlockDeviceManager.new(logger)
          manager.vm_type = {
            'key_name' => 'bar',
            'availability_zone' => 'us-east-1a',
            'instance_type' => 'm3.xlarge',
            'ephemeral_disk' => {
              'size' => 4000,
              'encrypted' => true
            }
          }

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
          expect(manager.mappings).to match_array(expected_output)
        end
      end

      context 'when specifying use_instance_storage' do
        context 'when the instance_type has instance storage' do
          it 'returns instance storage disks as ephemeral disk' do
            manager = BlockDeviceManager.new(logger)
            manager.vm_type = {
              'key_name' => 'bar',
              'availability_zone' => 'us-east-1a',
              'instance_type' => 'm3.xlarge',
              'ephemeral_disk' => {
                'use_instance_storage' => true
              }
            }

            expected_disks = [
              {
                virtual_name: 'ephemeral0',
                device_name: '/dev/sdb',
              },
              default_root
            ]

            expect(manager.mappings).to match_array(expected_disks)
          end
        end

        context 'when the instance_type has NO instance storage' do
          it 'raises an error' do
            manager = BlockDeviceManager.new(logger)
            manager.vm_type = {
              'key_name' => 'bar',
              'availability_zone' => 'us-east-1a',
              'instance_type' => 't2.small',
              'ephemeral_disk' => {
                'use_instance_storage' => true
              }
            }

            expect { manager.mappings }.to raise_error(
                                             Bosh::Clouds::CloudError,
                                             "use_instance_storage requested for instance type 't2.small' that does not have instance storage"
                                           )
          end
        end

        context 'when any other properties are set for ephemeral_disk' do
          it 'raises an error' do
            manager = BlockDeviceManager.new(logger)
            manager.vm_type = {
              'key_name' => 'bar',
              'availability_zone' => 'us-east-1a',
              'instance_type' => 'm3.medium',
              'ephemeral_disk' => {
                'use_instance_storage' => true,
                'size' => 512
              }
            }

            expect { manager.mappings }.to raise_error(
                                             Bosh::Clouds::CloudError,
                                             "use_instance_storage cannot be combined with additional ephemeral_disk properties"
                                           )
          end
        end

        context 'when raw_instance_storage is also set' do
          it 'raises an error' do
            manager = BlockDeviceManager.new(logger)
            manager.vm_type = {
              'key_name' => 'bar',
              'availability_zone' => 'us-east-1a',
              'instance_type' => 'm3.medium',
              'ephemeral_disk' => {
                'use_instance_storage' => true
              },
              'raw_instance_storage' => true
            }

            expect { manager.mappings }.to raise_error(
                                             Bosh::Clouds::CloudError,
                                             "ephemeral_disk.use_instance_storage and raw_instance_storage cannot both be true"
                                           )
          end
        end
      end

      context 'when root disk is specified' do
        it 'should default root disk type to gp2 if type is not specified' do
          manager = BlockDeviceManager.new(logger)
          manager.vm_type = {
            'key_name' => 'bar',
            'availability_zone' => 'us-east-1a',
            'instance_type' => 'm3.medium',
            'root_disk' => {
              'size' => 42 * 1024.0
            }
          }

          expected_disks = [
            {
              device_name: '/dev/xvda',
              ebs: {
                volume_size: 42,
                volume_type: 'gp2',
                delete_on_termination: true,
              }
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

          expect(manager.mappings).to match_array(expected_disks)
        end

        context 'when root disk type is io1' do
          it 'should create disk type of io1 with iops' do
            manager = BlockDeviceManager.new(logger)
            manager.vm_type = {
              'key_name' => 'bar',
              'availability_zone' => 'us-east-1a',
              'instance_type' => 'm3.medium',
              'root_disk' => {
                'type' => 'io1',
                'size' => 42 * 1024.0,
                'iops' => 1000
              }
            }
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

            actual_disks = manager.mappings
            expect(actual_disks).to match_array(expected_disks)
          end
        end

        it 'should set device name if virtualization type is not hvm' do
          manager = BlockDeviceManager.new(logger)
          manager.vm_type = {
            'key_name' => 'bar',
            'availability_zone' => 'us-east-1a',
            'instance_type' => 'm3.medium',
            'root_disk' => {
              'size' => 42 * 1024.0
            }
          }
          manager.virtualization_type = 'paravirtual'

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

          actual_disks = manager.mappings
          expect(actual_disks).to match_array(expected_disks)
        end
      end
    end

    describe '#agent_info' do

      context 'when raw_instance_storage is false' do

        context 'when instance type has instance storage' do
          it 'returns information about the first managed instance storage disk, ignoring the other disks' do
            manager = BlockDeviceManager.new(logger)
            manager.vm_type = {
              'key_name' => 'bar',
              'availability_zone' => 'us-east-1a',
              'instance_type' => 'm3.xlarge',
              'raw_instance_storage' => false
            }

            expect(manager.agent_info).to eq(
              {
                'ephemeral' => [{'path' => '/dev/sdb'}],
              }
            )
          end
        end

        context 'when instance type does not have instance storage' do
          it 'returns information about the first managed EBS disk' do
            manager = BlockDeviceManager.new(logger)
            manager.vm_type = {
              'key_name' => 'bar',
              'availability_zone' => 'us-east-1a',
              'instance_type' => 't2.small',
              'raw_instance_storage' => false
            }

            expect(manager.agent_info).to eq({
                                               'ephemeral' => [{'path' => '/dev/sdb'}],
                                             })
          end
        end
      end

      context 'when raw_instance_storage is true' do
        it 'returns information about a managed EBS disk and the raw ephemeral instance disks' do
          manager = BlockDeviceManager.new(logger)
          manager.vm_type = {
            'key_name' => 'bar',
            'availability_zone' => 'us-east-1a',
            'instance_type' => 'm3.xlarge',
            'raw_instance_storage' => true
          }

          expect(manager.agent_info).to eq({
                                             'ephemeral' => [{'path' => '/dev/sdb'}],
                                             'raw_ephemeral' => [{'path' => '/dev/xvdba'}, {'path' => '/dev/xvdbb'}],
                                           })
        end
      end

      context 'when root_disk is specified' do
        it 'returns information about a managed EBS disk' do
          manager = BlockDeviceManager.new(logger)
          manager.vm_type = {
            'key_name' => 'bar',
            'availability_zone' => 'us-east-1a',
            'instance_type' => 'm3.xlarge',
            'root_disk' => {
              'size' => 42 * 1024.0,
              'type' => 'st1'
            }
          }

          expect(manager.agent_info).to eq({
                                             'ephemeral' => [{'path' => '/dev/sdb'}],
                                           })
        end
      end
    end
  end
end
