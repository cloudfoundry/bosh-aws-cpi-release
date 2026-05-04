require 'integration/spec_helper'
require 'cloud'

describe 'spot instance provisioning' do
  let(:logger) { Bosh::Cpi::Logger.new(STDOUT) }

  let(:cpi_v2_options) do
    {
      'aws' => {
        'region'                  => @region,
        'default_key_name'        => @default_key_name,
        'default_security_groups' => get_security_group_ids,
        'fast_path_delete'        => 'yes',
        'access_key_id'           => @access_key_id,
        'secret_access_key'       => @secret_access_key,
        'session_token'           => @session_token,
        'max_retries'             => 8,
        'vm'                      => { 'stemcell' => { 'api_version' => 2 } },
      },
    }
  end

  let(:cpi_v2) { Bosh::AwsCloud::CloudV2.new(cpi_v2_options) }
  let(:ami)    { ENV.fetch('BOSH_AWS_IMAGE_ID') }
  let(:disks)  { [] }

  let(:network_spec) do
    {
      'default' => {
        'type'             => 'dynamic',
        'cloud_properties' => { 'subnet' => @subnet_id },
      }
    }
  end

  let(:vm_type) do
    {
      'instance_type'     => 'm4.large',
      'availability_zone' => @subnet_zone,
      'spot_bid_price'    => ENV.fetch('BOSH_AWS_SPOT_BID_PRICE', '0.10').to_f,
    }
  end

  # delete_me tag is required so the before(:each) cleanup in spec_helper can
  # terminate any leftover instances from interrupted test runs
  let(:vm_metadata) { { deployment: 'spot-integration-test', delete_me: 'please' } }

  before { allow(Bosh::Clouds::Config).to receive_messages(logger: logger) }

  it 'provisions a spot instance via RunInstances with InstanceMarketOptions' do
    skip 'spot instances not supported in cn-north-1' if @region == 'cn-north-1'

    vm_lifecycle(cpi: cpi_v2, ami_id: ami) do |instance_id|
      resp = @ec2.client.describe_instances(instance_ids: [instance_id])
      instance = resp.reservations[0].instances[0]

      lifecycle = instance.instance_lifecycle
      expect(lifecycle).to eq('spot'),
        "Expected InstanceLifecycle to be 'spot' but was '#{lifecycle.inspect}'"

      tags = instance.tags.each_with_object({}) { |t, h| h[t.key] = t.value }
      expect(tags).not_to be_empty
      expect(tags['deployment']).to eq('spot-integration-test')
      expect(tags['delete_me']).to eq('please')
    end
  end
end
