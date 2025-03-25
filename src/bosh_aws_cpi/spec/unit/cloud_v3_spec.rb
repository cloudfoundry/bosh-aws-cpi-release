require 'spec_helper'

describe Bosh::AwsCloud::CloudV3 do
  subject(:cloud) { described_class.new(options) }

  let(:cloud_core) { instance_double(Bosh::AwsCloud::CloudCore) }
  let(:options) { mock_cloud_options['properties'] }
  let(:az_selector) { instance_double(Bosh::AwsCloud::AvailabilityZoneSelector) }

  before do
    allow(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(az_selector)
  end

  describe '#initialize' do

    context 'if stemcell api_version is 3' do
      let(:options) do
        mock_cloud_properties_merge(
          {
            'aws' => {
              'vm' => {
                'stemcell' => {
                  'api_version' => 3
                }
              }
            }
          }
        )
      end

      it 'should initialize cloud_core with agent_version 3' do
        allow(Bosh::AwsCloud::CloudCore).to receive(:new).and_return(cloud_core)
        expect(Bosh::AwsCloud::CloudCore).to receive(:new).with(anything, anything, anything, anything, 3).and_return(cloud_core)
        described_class.new(options)
      end

      context "no stemcell api version in options" do
        let(:options) do
          mock_cloud_properties_merge(
            {
              'aws' => {
                'vm' => {}
              }
            }
          )
        end
        it 'should initialize cloud_core with default stemcell api version of 1' do
          allow(Bosh::AwsCloud::CloudCore).to receive(:new).and_return(cloud_core)
          expect(Bosh::AwsCloud::CloudCore).to receive(:new).with(anything, anything, anything, anything, 1).and_return(cloud_core)
          described_class.new(options)
        end
      end
    end
  end

  shared_examples 'handle tags' do
    let(:ami_id) { 'ami-image-id' }
     let(:encrypted_ami) { instance_double(Aws::EC2::Image, state: 'available', id: "#{ami_id}-copy") }
      let(:provider) { instance_double(Bosh::AwsCloud::AwsProvider) }
      let(:tag_manager) { class_double(Bosh::AwsCloud::TagManager) }
      let(:props_factory) { instance_double(Bosh::AwsCloud::StemcellCloudProps) }
      let(:image) { instance_double(Aws::EC2::Image, id: ami_id) }
      let(:image_copy) { instance_double(Aws::EC2::Image, image_id: "#{ami_id}-copy", id: "#{ami_id}-copy") }

      before do 
        allow(image).to receive(:id).and_return(ami_id)
        allow(image_copy).to receive(:id).and_return("#{ami_id}-copy")
        allow(image).to receive(:create_tags)
        allow(image_copy).to receive(:create_tags)
      end

      it 'if provided' do
        env = {"tags" => {"any"=>"value"}}
        expect(tag_manager).to receive(:create_tags).with(image, env["tags"])
        cloud.create_stemcell(anything, stemcell_properties, env)
      end

      # it 'if tags are not provided' do
      #   env = {}
      #   expect(tag_manager).to_not receive(:create_tags)
      #   cloud.create_stemcell(anything, stemcell_properties, env)
      # end

      # it 'if tags are nil' do
      #   env = { "tags" => nil }
      #   expect(tag_manager).to_not receive(:create_tags)
      #   cloud.create_stemcell(anything, stemcell_properties, env)
      # end

      # it 'if no env is provided' do
      #   expect(tag_manager).to_not receive(:create_tags)
      #   cloud.create_stemcell(anything, stemcell_properties)
      # end

  end

  describe '#create_stemcell' do

    context 'light stemcell' do 

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

      let(:cloud) {
        cloud = mock_cloud_v3 do |ec2|
          expect(ec2).to receive(:images).with(
            filters: [{
              name: 'image-id',
              values: [ami_id],
            }],
            include_deprecated: true,
          ).and_return([image])
        end
      }
      
      it_should_behave_like('handle tags')

    end

    # context 'encrypted flag is true' do 

    #   let(:kms_key_arn) { nil }
    #   let(:stemcell_properties) do
    #     {
    #         'encrypted' => true,
    #         'ami' => {
    #             'us-east-1' => ami_id
    #         }
    #       }
    #   end
    #   let(:cloud) {    
    #     cloud = mock_cloud_v3 do |ec2|
    #       expect(ec2).to receive(:images).with(
    #         filters: [{
    #           name: 'image-id',
    #           values: [ami_id],
    #         }],
    #         include_deprecated: true,
    #       ).and_return([image])

    #       expect(ec2.client).to receive(:copy_image).with(
    #         source_region: 'us-east-1',
    #         source_image_id: ami_id,
    #         name: "Copied from SourceAMI #{ami_id}",
    #         encrypted: true,
    #         kms_key_id: kms_key_arn
    #       ).and_return(image_copy)

    #       expect(ec2).to receive(:image).with("ami-image-id-copy").and_return(encrypted_ami)
         
    #       expect(Bosh::AwsCloud::ResourceWait).to receive(:for_image).with(
    #         image: encrypted_ami,
    #         state: 'available'
    #         )
    #     end
    #       # expect(encrypted_ami).to receive(:create_tags)
    #     }
        

    #   it_should_behave_like('handle tags')

    # end

  end


end
