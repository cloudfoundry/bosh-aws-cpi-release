require 'spec_helper'

describe Bosh::AwsCloud::RegistryDisabledClient do
  subject { described_class.new }

  context '#update_settings' do
    it 'should raise an error' do
      expect {
        subject.update_settings('myinstanceid', {})
      }.to raise_error(Bosh::Clouds::CloudError, 'An attempt to update registry settings has failed for instance_id=myinstanceid. The registry is disabled.')
    end
  end

  context '#read_settings' do
    it 'should raise an error' do
      expect {
        subject.read_settings('myinstanceid')
      }.to raise_error(Bosh::Clouds::CloudError, 'An attempt to read registry settings has failed for instance_id=myinstanceid. The registry is disabled.')
    end
  end

  context '#delete_settings' do
    it 'should raise an error' do
      expect {
        subject.delete_settings('myinstanceid')
      }.to raise_error(Bosh::Clouds::CloudError, 'An attempt to delete registry settings has failed for instance_id=myinstanceid. The registry is disabled.')
    end
  end
end