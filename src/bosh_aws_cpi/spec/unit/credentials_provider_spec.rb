require "spec_helper"
require "webmock/rspec"

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

    describe 'authenticating EC2 API requests' do
      let(:cloud) { Bosh::AwsCloud::Cloud.new(options) }
      let(:options) {
        mock_cloud_properties_merge({
          "aws" => {
              "region" => "bar"
          }
        })
      }
      let(:region_body) {
        '<DescribeRegionsResponse xmlns="http://ec2.amazonaws.com/doc/2015-10-01/">
           <requestId>59dbff89-35bd-4eac-99ed-be587EXAMPLE</requestId>
           <regionInfo>
              <item>
                 <regionName>bar</regionName>
                 <regionEndpoint>ec2.bar.amazonaws.com</regionEndpoint>
              </item>
           </regionInfo>
        </DescribeRegionsResponse>'
      }

      before do
        stub_request(:post, "https://ec2.bar.amazonaws.com/")
          .with(:body => /^Action=DescribeRegions.*$/)
          .to_return(:status => 200, :body => region_body, :headers => {})
        stub_request(:get, "http://169.254.169.254/latest/meta-data/instance-id/")
      end

      context 'when configured for "static" credentials' do
        it 'uses the statically-provided credentials (does not make a metadata request)' do
          options['aws'].merge!({
            "credentials_source" => "static",
            "access_key_id" => "access",
            "secret_access_key" => "secret"
          })

          cloud.current_vm_id
        end
      end

      context 'when configured for "env_or_profile" credentials' do
        let(:iam_response_body) {
          '{
            "Code" : "Success",
            "LastUpdated" : "2016-03-10T17:39:04Z",
            "Type" : "AWS-HMAC",
            "AccessKeyId" : "fake-access-key",
            "SecretAccessKey" : "fake-secret-key",
            "Token" : "fake-token",
            "Expiration" : "2016-03-10T23:46:04Z"
          }'
        }


        it 'retrieves credentials from the instance metadata endpoint' do
          options['aws'].merge!({
            "credentials_source" => "env_or_profile",
            "access_key_id" => nil,
            "secret_access_key" => nil
          })

          stub_request(:get, "http://169.254.169.254/latest/meta-data/iam/security-credentials/")
            .to_return(:status => 200, :body => "fake-iam-role", :headers => {})
          stub_request(:get, "http://169.254.169.254/latest/meta-data/iam/security-credentials/fake-iam-role")
            .to_return(:status => 200, :body => iam_response_body, :headers => {})

          cloud.current_vm_id
        end
      end
    end
  end
end
