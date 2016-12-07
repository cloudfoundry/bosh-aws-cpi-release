# Copyright (c) 2009-2012 VMware, Inc.

require 'spec_helper'

describe Bosh::AwsCloud::Cloud do

  let(:zones) { [double('us-east-1a', :name => 'us-east-1a')] }
  let(:volume) { double('volume', :id => 'v-foobar') }
  let(:instance) { double('instance', id: 'i-test', availability_zone: 'foobar-land') }
  let(:low_level_client) { instance_double('Aws::EC2::Client::V20141001') }
  let(:volume_resp) { double('Aws::Core::Response', volume_id: 'v-foobar') }

  before do
    allow(Bosh::AwsCloud::ResourceWait).to receive(:for_volume).with(volume: volume, state: :available)
    @cloud = mock_cloud do |_ec2|
      @ec2 = _ec2
      allow(@ec2).to receive_messages(:availability_zones => zones)
      allow(@ec2).to receive_messages(instances: double('instances', :[] => instance))
      allow(@ec2).to receive(:config).and_return('fake-config')
      allow(@ec2).to receive(:client).and_return(low_level_client)
      allow(low_level_client).to receive(:create_volume).and_return(volume_resp)

      allow(Aws::EC2::Volume).to receive(:new_from)
        .with(:create_volume, volume_resp, 'v-foobar', config: 'fake-config')
        .and_return(volume)
    end
  end

  it 'creates an EC2 volume' do
    expect(@cloud.create_disk(2048, {})).to eq('v-foobar')
    expect(low_level_client).to have_received(:create_volume) do |params|
      expect(params[:size]).to eq(2)
    end
  end

  it 'rounds up disk size' do
    @cloud.create_disk(2049, {})
    expect(low_level_client).to have_received(:create_volume) do |params|
      expect(params[:size]).to eq(3)
    end
  end

  it 'puts disk in the same AZ as an instance' do
    @cloud.create_disk(1024, {}, 'i-test')

    expect(low_level_client).to have_received(:create_volume) do |params|
      expect(params[:availability_zone]).to eq('foobar-land')
    end
  end

  it 'should pick a random availability zone when no instance is given' do
    @cloud.create_disk(2048, {})
    expect(low_level_client).to have_received(:create_volume) do |params|
      expect(params[:availability_zone]).to eq('us-east-1a')
    end
  end

  context 'cloud properties' do
    describe 'volume type' do
      it 'defaults to gp2' do
        @cloud.create_disk(2048, {})

        expect(low_level_client).to have_received(:create_volume) do |params|
          expect(params[:volume_type]).to eq('gp2')
        end
      end

      it 'is pulled from cloud properties' do
        @cloud.create_disk(2048, { 'type' => 'standard' })

        expect(low_level_client).to have_received(:create_volume) do |params|
          expect(params[:volume_type]).to eq('standard')
        end
      end
    end

    describe 'encryption' do
      it 'defaults to unencrypted' do
        @cloud.create_disk(2048, {})

        expect(low_level_client).to have_received(:create_volume) do |params|
          expect(params[:encrypted]).to eq(false)
        end
      end

      it 'passes through encryped => true' do
        @cloud.create_disk(2048, { 'encrypted' => true })

        expect(low_level_client).to have_received(:create_volume) do |params|
          expect(params[:encrypted]).to eq(true)
        end
      end
    end
  end
end
