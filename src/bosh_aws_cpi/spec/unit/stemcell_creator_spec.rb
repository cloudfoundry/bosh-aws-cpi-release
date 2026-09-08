require 'spec_helper'

module Bosh::AwsCloud
  describe StemcellCreator do
    let(:ec2_client) { instance_double(Aws::EC2::Client) }
    let(:ec2_config) { double('ec2_config', region: 'us-east-1', credentials: nil) }
    let(:ec2_resource) { instance_double(Aws::EC2::Resource, client: ec2_client) }
    let(:properties) do
      {
        'name' => 'stemcell-name',
        'version' => '0.7.0',
        'infrastructure' => 'aws',
        'architecture' => 'x86_64',
        'root_device_name' => '/dev/sda1',
        'virtualization_type' => virtualization_type,
      }
    end
    let(:virtualization_type) { 'paravirtual' }
    let(:aws_config) do
      instance_double(Bosh::AwsCloud::AwsConfig, stemcell: {}, encrypted: false, kms_key_arn: nil)
    end
    let(:global_config) { instance_double(Bosh::AwsCloud::Config, aws: aws_config) }
    let(:stemcell_cloud_props) { Bosh::AwsCloud::StemcellCloudProps.new(properties, global_config) }

    before do
      allow(Bosh::AwsCloud::AKIPicker).to receive(:new).and_return(double('aki', :pick => 'aki-xxxxxxxx'))
      allow(ec2_client).to receive(:config).and_return(ec2_config)
    end

    describe '#image_params' do
      context 'when virtualization type is paravirtual, and no kernel_id is specified' do
        let(:virtualization_type) { 'paravirtual' }

        before { properties.delete('kernel_id') }

        it 'constructs correct image params' do
          params = StemcellCreator.new(ec2_resource, stemcell_cloud_props).send(:image_params, 'id')

          expect(params[:architecture]).to eq('x86_64')
          expect(params[:description]).to eq('stemcell-name 0.7.0')
          expect(params[:kernel_id]).to eq('aki-xxxxxxxx')
          expect(params[:root_device_name]).to eq('/dev/sda1')
          expect(params[:block_device_mappings]).to eq([
            {
              :device_name => '/dev/sda',
              :ebs => { :snapshot_id => 'id' },
            },
            {
              :device_name => '/dev/sdb',
              :virtual_name => 'ephemeral0',
            },
          ])
          expect(params[:tag_specifications].first[:resource_type]).to eq('image')
          expect(params[:tag_specifications].first[:tags]).to include(
            { key: 'Name', value: 'stemcell-name 0.7.0' }
          )
        end
      end

      context 'when virtualization is paravirtual, and kernel_id is specified' do
        let(:virtualization_type) { 'paravirtual' }

        before { properties['kernel_id'] = 'aki-zzzzzzzz' }

        it 'constructs the image params, including the specified kernel_id' do
          params = StemcellCreator.new(ec2_resource, stemcell_cloud_props).send(:image_params, 'id')
          expect(params[:kernel_id]).to eq('aki-zzzzzzzz')
        end
      end

      context 'when the virtualization type is hvm' do
        let(:virtualization_type) { 'hvm' }

        it 'should construct correct image params' do
          params = described_class.new(ec2_resource, stemcell_cloud_props).send(:image_params, 'id')

          expect(params[:architecture]).to eq('x86_64')
          expect(params[:description]).to eq('stemcell-name 0.7.0')
          expect(params).not_to have_key(:kernel_id)
          expect(params[:root_device_name]).to eq('/dev/xvda')
          expect(params[:sriov_net_support]).to eq('simple')
          expect(params[:boot_mode]).to eq('legacy-bios')
          expect(params[:block_device_mappings]).to eq([
            {
              :device_name => '/dev/xvda',
              :ebs => { :snapshot_id => 'id' },
            },
            {
              :device_name => '/dev/sdb',
              :virtual_name => 'ephemeral0',
            },
          ])
          expect(params[:virtualization_type]).to eq('hvm')
          expect(params[:ena_support]).to be(true)
          expect(params[:tag_specifications].first[:resource_type]).to eq('image')
          expect(params[:tag_specifications].first[:tags]).to include(
            { key: 'Name', value: 'stemcell-name 0.7.0' }
          )
        end
      end
    end

    describe '#create' do
      let(:ebs_client) { instance_double(Aws::EBS::Client) }
      let(:creator) { described_class.new(ec2_resource, stemcell_cloud_props) }

      before do
        allow(Aws::EBS::Client).to receive(:new).and_return(ebs_client)
        allow(SecureRandom).to receive(:uuid).and_return('fake-uuid')
      end

      it 'forwards the tags: kwarg to tag_snapshot' do
        stemcell = instance_double(Bosh::AwsCloud::Stemcell)
        allow(creator).to receive(:extract_root_image)
        allow(creator).to receive(:write_snapshot_via_ebs_direct).and_return('snap-tagged')
        expect(creator).to receive(:tag_snapshot).with('snap-tagged').ordered
        allow(creator).to receive(:register_image_from_snapshot).and_return(stemcell)

        creator.create('/path/to/image.tgz', encrypted: false, kms_key_arn: nil, tags: { 'env' => 'test' })
        expect(creator.instance_variable_get(:@creation_tags)).to eq({ 'env' => 'test' })
      end
    end
  end
end
