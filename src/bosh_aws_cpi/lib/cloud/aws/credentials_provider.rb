# module Bosh::AwsCloud
#   class CredentialsProvider < Aws::Core::CredentialProviders::DefaultProvider
#     DEFAULT_RETRIES = 10
#
#     def initialize(static_credentials = {})
#       @providers = []
#       @providers << Aws::Core::CredentialProviders::StaticProvider.new(static_credentials)
#       @providers << Aws::Core::CredentialProviders::EC2Provider.new(:retries => DEFAULT_RETRIES)
#     end
#   end
# end
