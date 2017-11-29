require 'spec_helper'

describe Bosh::AwsCloud::Cloud do
  before { @tmp_dir = Dir.mktmpdir }
  after { FileUtils.rm_rf(@tmp_dir) }

  describe 'EBS-volume based flow' do
    let(:creator) { double(Bosh::AwsCloud::StemcellCreator) }
    let(:volume_manager) { instance_double(Bosh::AwsCloud::VolumeManager) }
    let(:az_selector) do
      instance_double(Bosh::AwsCloud::AvailabilityZoneSelector, select_availability_zone: 'us-east-1a')
    end
    let(:disk_config) do
      {
        size: 2,
        availability_zone: 'us-east-1a',
        volume_type: 'gp2',
        encrypted: false
      }
    end

    context 'light stemcell' do
      let(:ami_id) { 'ami-xxxxxxxx' }
      let(:encrypted_ami) { instance_double(Aws::EC2::Image, state: 'available') }
      let(:stemcell_properties) do
        {
          'root_device_name' => '/dev/sda1',
          'architecture' => 'x86_64',
          'name' => 'stemcell-name',
          'version' => '1.2.3',
          'ami' => {
            'us-east-1' => ami_id
          }
        }
      end

      it 'should return a light stemcell' do
        cloud = mock_cloud do |ec2|
          expect(ec2).to receive(:images).with(
            filters: [{
              name: 'image-id',
              values: [ami_id],
            }],
          ).and_return([double('image', id: ami_id)])
        end
        expect(cloud.create_stemcell('/tmp/foo', stemcell_properties)).to eq("#{ami_id} light")
      end

      context 'when encrypted flag is true' do
        let(:kms_key_arn) { nil }
        let(:stemcell_properties) do
          {
            'encrypted' => true,
            'ami' => {
                'us-east-1' => ami_id
            }
          }
        end

        it 'should copy ami' do
          cloud = mock_cloud do |ec2|
            expect(ec2).to receive(:images).with(
              filters: [{
                name: 'image-id',
                values: [ami_id],
              }],
            ).and_return([double('image', id: ami_id)])

            expect(ec2.client).to receive(:copy_image).with(
              source_region: 'us-east-1',
              source_image_id: ami_id,
              name: "Copied from SourceAMI #{ami_id}",
              encrypted: true,
              kms_key_id: kms_key_arn
            ).and_return(double('copy_image_result', image_id: 'ami-newami'))

            expect(ec2).to receive(:image).with('ami-newami').and_return(encrypted_ami)

            expect(Bosh::AwsCloud::ResourceWait).to receive(:for_image).with(
              image: encrypted_ami,
              state: 'available'
            )
          end

          cloud.create_stemcell('/tmp/foo', stemcell_properties)
        end

        it 'should return stemcell id (not light stemcell id)' do
          cloud = mock_cloud do |ec2, client|
            expect(ec2).to receive(:images).with(
              filters: [{
                name: 'image-id',
                values: [ami_id],
              }],
            ).and_return([double('image', id: ami_id)])

            expect(ec2.client).to receive(:copy_image).with(
              source_region: 'us-east-1',
              source_image_id: ami_id,
              name: "Copied from SourceAMI #{ami_id}",
              encrypted: true,
              kms_key_id: kms_key_arn
            ).and_return(double('copy_image_result', image_id: 'ami-newami'))

            expect(ec2).to receive(:image).with('ami-newami').and_return(encrypted_ami)

            expect(Bosh::AwsCloud::ResourceWait).to receive(:for_image).with(
              image: encrypted_ami,
              state: 'available'
            )
          end

          expect(cloud.create_stemcell('/tmp/foo', stemcell_properties)).to eq('ami-newami')
        end
      end

      context 'and kms_key_arn is given' do
        let(:kms_key_arn) { 'arn:aws:kms:us-east-1:12345678:key/guid' }
        let(:stemcell_properties) do
          {
            'encrypted' => true,
            'kms_key_arn' => kms_key_arn,
            'ami' => {
                'us-east-1' => ami_id
            }
          }
        end

        it 'should encrypt ami with given kms_key_arn' do
          cloud = mock_cloud do |ec2, client|
            expect(ec2).to receive(:images).with(
              filters: [{
                name: 'image-id',
                values: [ami_id],
              }],
            ).and_return([double('image', id: ami_id)])

            expect(ec2.client).to receive(:copy_image).with(
              source_region: 'us-east-1',
              source_image_id: ami_id,
              name: "Copied from SourceAMI #{ami_id}",
              encrypted: true,
              kms_key_id: kms_key_arn
            ).and_return(double('copy_image_result', image_id: 'ami-newami'))

            expect(ec2).to receive(:image).with('ami-newami').and_return(encrypted_ami)

            expect(Bosh::AwsCloud::ResourceWait).to receive(:for_image).with(
              image: encrypted_ami,
              state: 'available'
            )
          end

          cloud.create_stemcell('/tmp/foo', stemcell_properties)
        end
      end

      context 'when ami does NOT exist' do
        it 'should return error' do
          cloud = mock_cloud do |ec2|
            allow(ec2).to receive(:images).with(
              filters: [{
                name: 'image-id',
                values: ['ami-xxxxxxxx']
              }]
            ).and_return([])
          end
          expect{
            cloud.create_stemcell('/tmp/foo', stemcell_properties)
          }.to raise_error(/Stemcell does not contain an AMI in region/)
        end
      end
    end

    context 'heavy stemcell' do
      let(:stemcell_properties) do
        {
          'root_device_name' => '/dev/sda1',
          'architecture' => 'x86_64',
          'name' => 'stemcell-name',
          'version' => '1.2.3',
          'virtualization_type' => 'paravirtual'
        }
      end
      let(:volume) { double('volume', :id => 'vol-xxxxxxxx') }
      let(:stemcell) { double('stemcell', :id => 'ami-xxxxxxxx') }
      let(:instance) { double('instance') }
      let(:aws_config) do
        instance_double(Bosh::AwsCloud::AwsConfig, stemcell: {}, encrypted: false, kms_key_arn: nil)
      end
      let(:global_config) { instance_double(Bosh::AwsCloud::Config, aws: aws_config) }
      let(:stemcell_cloud_props) { Bosh::AwsCloud::StemcellCloudProps.new(stemcell_properties, global_config) }
      let(:props_factory) { instance_double(Bosh::AwsCloud::PropsFactory) }

      before do
        allow(Bosh::AwsCloud::PropsFactory).to receive(:new)
          .and_return(props_factory)
        allow(props_factory).to receive(:stemcell_props)
          .with(stemcell_properties)
          .and_return(stemcell_cloud_props)
      end

      it 'should create a stemcell' do
        cloud = mock_cloud do |ec2|
          allow(ec2).to receive(:volume).with('vol-xxxxxxxx').and_return(volume)
          allow(ec2).to receive(:instance).with('i-xxxxxxxx').and_return(instance)

          expect(Bosh::AwsCloud::StemcellCreator).to receive(:new)
            .with(ec2, stemcell_cloud_props)
            .and_return(creator)
          expect(Bosh::AwsCloud::VolumeManager).to receive(:new).and_return(volume_manager)
          expect(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(az_selector)
        end

        allow(instance).to receive(:exists?).and_return(true)
        allow(instance).to receive(:reload).and_return(instance)
        allow(cloud).to receive(:current_vm_id).and_return('i-xxxxxxxx')

        expect(volume_manager).to receive(:create_ebs_volume).with(disk_config).and_return(volume)
        expect(volume_manager).to receive(:attach_ebs_volume).with(instance, volume).and_return('/dev/sdh')
        expect(cloud).to receive(:find_device_path_by_name).with('/dev/sdh').and_return('ebs')

        expect(creator).to receive(:create).with(volume, 'ebs', '/tmp/foo').and_return(stemcell)

        expect(volume_manager).to receive(:detach_ebs_volume).with(instance, volume, true)
        expect(volume_manager).to receive(:delete_ebs_volume).with(volume)

        expect(cloud.create_stemcell('/tmp/foo', stemcell_properties)).to eq('ami-xxxxxxxx')
      end

      context 'when the CPI configuration includes a kernel_id for stemcell' do
        it 'creates a stemcell' do
          options = mock_cloud_options['properties']
          options['aws']['stemcell'] = {'kernel_id' => 'fake-kernel-id'}
          cloud = mock_cloud(options) do |ec2|
            allow(ec2).to receive(:volume).with('vol-xxxxxxxx').and_return(volume)
            allow(ec2).to receive(:instance).with('i-xxxxxxxx').and_return(instance)

            stemcell_properties.merge('kernel_id' => 'fake-kernel-id')
            expect(Bosh::AwsCloud::StemcellCreator).to receive(:new)
              .with(ec2, stemcell_cloud_props)
              .and_return(creator)
            expect(Bosh::AwsCloud::VolumeManager).to receive(:new).and_return(volume_manager)
            expect(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(az_selector)
          end

          allow(instance).to receive(:exists?).and_return(true)
          allow(instance).to receive(:reload).and_return(instance)
          allow(cloud).to receive(:current_vm_id).and_return('i-xxxxxxxx')

          expect(volume_manager).to receive(:create_ebs_volume).with(disk_config).and_return(volume)
          expect(volume_manager).to receive(:attach_ebs_volume).with(instance, volume).and_return('/dev/sdh')
          expect(cloud).to receive(:find_device_path_by_name).with('/dev/sdh').and_return('ebs')

          allow(creator).to receive(:create)
          expect(creator).to receive(:create).with(volume, 'ebs', '/tmp/foo').and_return(stemcell)

          expect(volume_manager).to receive(:detach_ebs_volume).with(instance, volume, true)
          expect(volume_manager).to receive(:delete_ebs_volume).with(volume)

          expect(cloud.create_stemcell('/tmp/foo', stemcell_properties)).to eq('ami-xxxxxxxx')
        end
      end

      context 'when encrypted flag is set to true' do
        context 'and kms_key_arn is provided' do
          let(:stemcell_properties) do
            {
              'root_device_name' => '/dev/sda1',
              'architecture' => 'x86_64',
              'name' => 'stemcell-name',
              'version' => '1.2.3',
              'virtualization_type' => 'paravirtual',
              'encrypted' => true,
              'kms_key_arn' => 'arn:aws:kms:us-east-1:ID:key/GUID'
            }
          end
          let(:disk_config) do
            {
              size: 2,
              availability_zone: 'us-east-1a',
              volume_type: 'gp2',
              encrypted: true,
              kms_key_id: 'arn:aws:kms:us-east-1:ID:key/GUID'
            }
          end

          it 'should create stemcell with encrypted disk with the given kms key' do
            cloud = mock_cloud do |ec2|
              allow(ec2).to receive(:volume).with('vol-xxxxxxxx').and_return(volume)
              allow(ec2).to receive(:instance).with('i-xxxxxxxx').and_return(instance)

              expect(Bosh::AwsCloud::StemcellCreator).to receive(:new)
                                                             .with(ec2, stemcell_cloud_props)
                                                             .and_return(creator)
              expect(Bosh::AwsCloud::VolumeManager).to receive(:new).and_return(volume_manager)
              expect(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(az_selector)
            end

            allow(instance).to receive(:exists?).and_return(true)
            allow(instance).to receive(:reload).and_return(instance)
            allow(cloud).to receive(:current_vm_id).and_return('i-xxxxxxxx')

            expect(volume_manager).to receive(:create_ebs_volume).with(disk_config).and_return(volume)
            expect(volume_manager).to receive(:attach_ebs_volume).with(instance, volume).and_return('/dev/sdh')
            expect(cloud).to receive(:find_device_path_by_name).with('/dev/sdh').and_return('ebs')

            expect(creator).to receive(:create).with(volume, 'ebs', '/tmp/foo').and_return(stemcell)

            expect(volume_manager).to receive(:detach_ebs_volume).with(instance, volume, true)
            expect(volume_manager).to receive(:delete_ebs_volume).with(volume)

            expect(cloud.create_stemcell('/tmp/foo', stemcell_properties)).to eq('ami-xxxxxxxx')
          end
        end

        context 'and kms_key_arn is NOT provided' do
          let(:stemcell_properties) do
            {
              'root_device_name' => '/dev/sda1',
              'architecture' => 'x86_64',
              'name' => 'stemcell-name',
              'version' => '1.2.3',
              'virtualization_type' => 'paravirtual',
              'encrypted' => true
            }
          end
          let(:disk_config) do
            {
              size: 2,
              availability_zone: 'us-east-1a',
              volume_type: 'gp2',
              encrypted: true
            }
          end

          it 'should create stemcell with encrypted disk' do
            cloud = mock_cloud do |ec2|
              allow(ec2).to receive(:volume).with('vol-xxxxxxxx').and_return(volume)
              allow(ec2).to receive(:instance).with('i-xxxxxxxx').and_return(instance)

              expect(Bosh::AwsCloud::StemcellCreator).to receive(:new)
                                                             .with(ec2, stemcell_cloud_props)
                                                             .and_return(creator)
              expect(Bosh::AwsCloud::VolumeManager).to receive(:new).and_return(volume_manager)
              expect(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(az_selector)
            end

            allow(instance).to receive(:exists?).and_return(true)
            allow(instance).to receive(:reload).and_return(instance)
            allow(cloud).to receive(:current_vm_id).and_return('i-xxxxxxxx')

            expect(volume_manager).to receive(:create_ebs_volume).with(disk_config).and_return(volume)
            expect(volume_manager).to receive(:attach_ebs_volume).with(instance, volume).and_return('/dev/sdh')
            expect(cloud).to receive(:find_device_path_by_name).with('/dev/sdh').and_return('ebs')

            expect(creator).to receive(:create).with(volume, 'ebs', '/tmp/foo').and_return(stemcell)

            expect(volume_manager).to receive(:detach_ebs_volume).with(instance, volume, true)
            expect(volume_manager).to receive(:delete_ebs_volume).with(volume)

            expect(cloud.create_stemcell('/tmp/foo', stemcell_properties)).to eq('ami-xxxxxxxx')
          end
        end
      end

      context 'when encryption information is incomplete' do
        def test_for_unencrypted_root_disk()
          cloud = mock_cloud do |ec2|
            allow(ec2).to receive(:volume).with('vol-xxxxxxxx').and_return(volume)
            allow(ec2).to receive(:instance).with('i-xxxxxxxx').and_return(instance)

            expect(Bosh::AwsCloud::StemcellCreator).to receive(:new)
                                                           .with(ec2, stemcell_cloud_props)
                                                           .and_return(creator)
            expect(Bosh::AwsCloud::VolumeManager).to receive(:new).and_return(volume_manager)
            expect(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(az_selector)
          end

          allow(instance).to receive(:exists?).and_return(true)
          allow(instance).to receive(:reload).and_return(instance)
          allow(cloud).to receive(:current_vm_id).and_return('i-xxxxxxxx')

          expect(volume_manager).to receive(:create_ebs_volume).with(disk_config).and_return(volume)
          expect(volume_manager).to receive(:attach_ebs_volume).with(instance, volume).and_return('/dev/sdh')
          expect(cloud).to receive(:find_device_path_by_name).with('/dev/sdh').and_return('ebs')

          expect(creator).to receive(:create).with(volume, 'ebs', '/tmp/foo').and_return(stemcell)

          expect(volume_manager).to receive(:detach_ebs_volume).with(instance, volume, true)
          expect(volume_manager).to receive(:delete_ebs_volume).with(volume)

          expect(cloud.create_stemcell('/tmp/foo', stemcell_properties)).to eq('ami-xxxxxxxx')
        end
        let(:disk_config) do
          {
            size: 2,
            availability_zone: 'us-east-1a',
            volume_type: 'gp2',
            encrypted: false,
            kms_key_id: 'arn:aws:kms:us-east-1:ID:key/GUID'
          }
        end

        context 'when `encrypted` is false and kms_key_arn is provided' do
          let(:stemcell_properties) do
            {
              'root_device_name' => '/dev/sda1',
              'architecture' => 'x86_64',
              'name' => 'stemcell-name',
              'version' => '1.2.3',
              'virtualization_type' => 'paravirtual',
              'encrypted' => false,
              'kms_key_arn' => 'arn:aws:kms:us-east-1:ID:key/GUID'
            }
          end

          it 'should create an unencrypted stemcell' do
            test_for_unencrypted_root_disk
          end
        end

        context 'when `encrypted` is missing and kms_key_arn is provided' do
          let(:stemcell_properties) do
            {
              'root_device_name' => '/dev/sda1',
              'architecture' => 'x86_64',
              'name' => 'stemcell-name',
              'version' => '1.2.3',
              'virtualization_type' => 'paravirtual',
              'kms_key_arn' => 'arn:aws:kms:us-east-1:ID:key/GUID'
            }
          end

          it 'should create an unencrypted stemcell' do
            test_for_unencrypted_root_disk
          end
        end
      end

      describe '#find_device_path_by_name' do
        it 'should locate ebs volume on the current instance and return the device name' do
          cloud = mock_cloud

          allow(File).to receive(:blockdev?).with('/dev/sdf').and_return(true)

          expect(cloud.send(:find_device_path_by_name, '/dev/sdf')).to eq('/dev/sdf')
        end

        it 'should locate ebs volume on the current instance and return the virtual device name' do
          cloud = mock_cloud

          allow(File).to receive(:blockdev?).with('/dev/sdf').and_return(false)
          allow(File).to receive(:blockdev?).with('/dev/xvdf').and_return(true)

          expect(cloud.send(:find_device_path_by_name, '/dev/sdf')).to eq('/dev/xvdf')
        end
      end
    end
  end
end
