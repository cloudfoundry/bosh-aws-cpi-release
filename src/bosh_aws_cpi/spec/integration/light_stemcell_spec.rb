require 'integration/spec_helper'
require 'bosh/cpi/logger'
require 'cloud'

describe Bosh::AwsCloud::Cloud do
  before(:all) do
    @kms_key_arn = ENV['BOSH_AWS_KMS_KEY_ARN'] || raise('Missing BOSH_AWS_KMS_KEY_ARN')
  end

  let(:ami) { hvm_ami }
  let(:hvm_ami) { ENV.fetch('BOSH_AWS_IMAGE_ID', 'ami-9c91b7fc') }
  let(:registry) { instance_double(Bosh::Cpi::RegistryClient).as_null_object }
  let(:aws_config) do
    {
      'region' => @region,
      'default_key_name' => @default_key_name,
      'default_security_groups' => get_security_group_ids,
      'fast_path_delete' => 'yes',
      'access_key_id' => @access_key_id,
      'secret_access_key' => @secret_access_key,
      'max_retries' => 8,
      'encrypted' => true
    }
  end
  let(:cpi) do
    Bosh::AwsCloud::Cloud.new(
      'aws' => aws_config,
      'registry' => {
        'endpoint' => 'fake',
        'user' => 'fake',
        'password' => 'fake'
      }
    )
  end
  let(:logs) { STDOUT }
  let(:logger) { Bosh::Cpi::Logger.new(logs) }

  before { allow(Bosh::Clouds::Config).to receive_messages(logger: logger) }

  context 'create_stemcell for light-stemcell' do
    context 'when global config has encrypted true' do
      context 'and stemcell properties does NOT have encrypted' do
        let(:stemcell_properties) do
          {
            'ami' => {
              @region => ami
            }
          }
        end

        it 'should encrypt root disk' do
          begin
            stemcell_id = cpi.create_stemcell('/not/a/real/path', stemcell_properties)
            expect(stemcell_id).not_to eq("#{ami}")

            encrypted_ami = @ec2.image(stemcell_id.split[0])
            expect(encrypted_ami).not_to be_nil

            root_block_device = get_root_block_device(
              encrypted_ami.root_device_name,
              encrypted_ami.block_device_mappings
            )
            expect(root_block_device.ebs.encrypted).to be(true)
          ensure
            cpi.delete_stemcell(stemcell_id) if stemcell_id
          end
        end
      end

      context 'and encrypted is overwritten to false in stemcell properties' do
        let(:stemcell_properties) do
          {
            'encrypted' => false,
            'ami' => {
              @region => ami
            }
          }
        end

        it 'should NOT copy the AMI' do
          stemcell_id = cpi.create_stemcell('/not/a/real/path', stemcell_properties)
          expect(stemcell_id).to end_with(' light')
          expect(stemcell_id).to eq("#{ami} light")
        end
      end

      context 'and global kms_key_arn are provided' do
        let(:aws_config) do
          {
            'region' => @region,
            'default_key_name' => @default_key_name,
            'default_security_groups' => get_security_group_ids,
            'fast_path_delete' => 'yes',
            'access_key_id' => @access_key_id,
            'secret_access_key' => @secret_access_key,
            'max_retries' => 8,
            'encrypted' => true,
            'kms_key_arn' => @kms_key_arn
          }
        end

        context 'and encrypted is overwritten to false in stemcell properties' do
          let(:stemcell_properties) do
            {
              'encrypted' => false,
              'ami' => {
                @region => ami
              }
            }
          end

          it 'should NOT copy the AMI' do
            stemcell_id = cpi.create_stemcell('/not/a/real/path', stemcell_properties)
            expect(stemcell_id).to end_with(' light')
            expect(stemcell_id).to eq("#{ami} light")
          end
        end

        context 'and stemcell properties does NOT have kms_key_arn' do
          let(:stemcell_properties) do
            {
              'ami' => {
                @region => ami
              }
            }
          end

          it 'encrypts root disk with global kms_key_arn' do
            begin
              stemcell_id = cpi.create_stemcell('/not/a/real/path', stemcell_properties)
              expect(stemcell_id).to_not end_with(' light')
              expect(stemcell_id).not_to eq("#{ami}")

              encrypted_ami = @ec2.image(stemcell_id.split[0])
              expect(encrypted_ami).to_not be_nil

              root_block_device = get_root_block_device(encrypted_ami.root_device_name, encrypted_ami.block_device_mappings)
              encrypted_snapshot = @ec2.snapshot(root_block_device.ebs.snapshot_id)
              expect(encrypted_snapshot.encrypted).to be(true)
              expect(encrypted_snapshot.kms_key_id).to eq(@kms_key_arn)
            ensure
              cpi.delete_stemcell(stemcell_id) if stemcell_id
            end
          end
        end

        context 'and kms_key_arn is overwritten in stemcell properties' do
          let(:stemcell_properties) do
            {
              'kms_key_arn' => 'invalid-kms-key-arn-only-to-test-override',
              'ami' => {
                @region => ami
              }
            }
          end

          it 'should try to create root disk with stemcell properties kms_key_arn' do
            # It's faster to fail than providing another `kms_key_arn` and waiting for success
            # if the property wasn't being overwritten it would NOT fail
            expect do
              stemcell_id = cpi.create_stemcell('/not/a/real/path', stemcell_properties)
              cpi.delete_stemcell(stemcell_id) if stemcell_id
            end.to raise_error(Bosh::Clouds::CloudError)
          end
        end
      end
    end
  end
end