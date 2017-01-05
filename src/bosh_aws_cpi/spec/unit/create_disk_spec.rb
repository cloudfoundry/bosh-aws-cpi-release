# Copyright (c) 2009-2012 VMware, Inc.

require 'spec_helper'

describe Bosh::AwsCloud::Cloud do

  let(:zones) { [{ 'zone_name' => 'us-east-1a' }] }
  let(:volume) { double('volume', :id => 'v-foobar') }
  let(:instance) { double('instance', id: 'i-test', placement: double('placement', availability_zone: 'foobar-land')) }
  let(:volume_resp) { double('Aws::Core::Response', volume_id: 'v-foobar') }

  before do
    @cloud = mock_cloud do |_ec2|
      @ec2 = _ec2
      allow(@ec2).to receive(:instance).with('i-test').and_return(instance)
      allow(@ec2).to receive(:config).and_return('fake-config')
      allow(@ec2).to receive(:subnets).and_return([double('subnet')])
    end

    allow(@ec2.client).to receive(:create_volume).and_return(volume_resp)
    allow(@ec2.client).to receive(:describe_availability_zones).and_return({ 'availability_zones' => zones })

    allow(Bosh::AwsCloud::ResourceWait).to receive(:for_volume).with(volume: volume, state: 'available')
    allow(Aws::EC2::Volume).to receive(:new)
      .with(id: 'v-foobar', client: @ec2.client)
      .and_return(volume)
  end

  it 'creates an EC2 volume' do
    expect(@cloud.create_disk(2048, {})).to eq('v-foobar')
    expect(@ec2.client).to have_received(:create_volume) do |params|
      expect(params[:size]).to eq(2)
    end
  end

  it 'rounds up disk size' do
    @cloud.create_disk(2049, {})
    expect(@ec2.client).to have_received(:create_volume) do |params|
      expect(params[:size]).to eq(3)
    end
  end

  it 'puts disk in the same AZ as an instance' do
    @cloud.create_disk(1024, {}, 'i-test')

    expect(@ec2.client).to have_received(:create_volume) do |params|
      expect(params[:availability_zone]).to eq('foobar-land')
    end
  end

  it 'should pick a random availability zone when no instance is given' do
    @cloud.create_disk(2048, {})
    expect(@ec2.client).to have_received(:create_volume) do |params|
      expect(params[:availability_zone]).to eq('us-east-1a')
    end
  end

  context 'cloud properties' do
    describe 'volume type' do
      it 'defaults to gp2' do
        @cloud.create_disk(2048, {})

        expect(@ec2.client).to have_received(:create_volume) do |params|
          expect(params[:volume_type]).to eq('gp2')
        end
      end

      it 'is pulled from cloud properties' do
        @cloud.create_disk(2048, { 'type' => 'standard' })

        expect(@ec2.client).to have_received(:create_volume) do |params|
          expect(params[:volume_type]).to eq('standard')
        end
      end
    end

    describe 'encryption' do
      it 'defaults to unencrypted' do
        @cloud.create_disk(2048, {})

        expect(@ec2.client).to have_received(:create_volume) do |params|
          expect(params[:encrypted]).to eq(false)
        end
      end

      it 'passes through encryped => true' do
        @cloud.create_disk(2048, { 'encrypted' => true })

        expect(@ec2.client).to have_received(:create_volume) do |params|
          expect(params[:encrypted]).to eq(true)
        end
      end
    end
  end
end
