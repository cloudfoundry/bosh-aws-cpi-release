require "spec_helper"

module Bosh::AwsCloud
  describe CredentialsProvider do
    subject(:provider) { CredentialsProvider.new }
    let(:providers) { provider.providers }

    describe '#providers' do
      it 'includes two providers (static, ec2)' do
        expect(providers.length).to eq(2)
      end

      it 'includes a StaticProvider' do
        matched = providers.select do |entry|
          entry.is_a?(AWS::Core::CredentialProviders::StaticProvider)
        end
        expect(matched.length).to eq(1)
      end

      it 'includes a EC2Provider with retries > 0' do
        matched = providers.select do |entry|
          entry.is_a?(AWS::Core::CredentialProviders::EC2Provider)
        end
        expect(matched.length).to eq(1)
        expect(matched[0].retries).to eq(CredentialsProvider::DEFAULT_RETRIES)
      end
    end
  end
end
