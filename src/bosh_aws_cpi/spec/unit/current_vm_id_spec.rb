# Copyright (c) 2009-2012 VMware, Inc.

require 'spec_helper'
require 'webmock/rspec'

describe Bosh::AwsCloud::CloudV1 do

  describe '#current_vm_id' do
    let(:options) {
      mock_cloud_properties_merge({
         'aws' => {
           'region' => 'bar'
         }
      })
    }

    let(:cloud) { described_class.new(options) }

    before do
      stub_request(:post, 'https://ec2.bar.amazonaws.com/').
          to_return(:status => 200, :body => '', :headers => {})
    end

    let(:fake_instance_id) { 'i-xxxxxxxx' }

    it 'should make a call to AWS and return the correct vm id' do
      stub_request(:put, 'http://169.254.169.254/latest/api/token')
        .with(headers: { 'X-aws-ec2-metadata-token-ttl-seconds' => '300' })
        .to_return(:body => "token")
      stub_request(:get, 'http://169.254.169.254/latest/meta-data/instance-id/')
        .with(headers: { 'X-aws-ec2-metadata-token' => "token" })
        .to_return(:body => fake_instance_id)
      expect(cloud.current_vm_id).to eq(fake_instance_id)
    end

    it 'should ignore errors from the token endpoint, setting token to nil' do
      #we thought it made sense to be "defensive" about using IMDSv2 in case there are 
      #regions that do not support it. Expected behavior if our token call fails is that 
      #we simply call the instance-id endpoint without the token header and hope for the best. 
      stub_request(:put, 'http://169.254.169.254/latest/api/token')
        .with(headers: { 'X-aws-ec2-metadata-token-ttl-seconds' => '300' })
        .to_return(status: [500, "Internal Server Error"])
      stub_request(:get, 'http://169.254.169.254/latest/meta-data/instance-id/')
        .to_return(:body => fake_instance_id)
      expect(cloud.current_vm_id).to eq(fake_instance_id)
    end

    it 'if instance-id endpoint errors, throw a cloud_error' do
      stub_request(:put, 'http://169.254.169.254/latest/api/token')
        .with(headers: { 'X-aws-ec2-metadata-token-ttl-seconds' => '300' })
        .to_return(:body => "token")
      stub_request(:get, 'http://169.254.169.254/latest/meta-data/instance-id/')
        .with(headers: { 'X-aws-ec2-metadata-token' => "token" })
        .to_return(status: [500, "Internal Server Error"])
      expect{
        cloud.current_vm_id
      }.to raise_error Bosh::Clouds::CloudError
    end
  end
end
