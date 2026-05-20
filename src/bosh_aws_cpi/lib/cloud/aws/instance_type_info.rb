module Bosh::AwsCloud
  # Provides instance type metadata by querying the EC2 DescribeInstanceTypes API.
  # Results are cached for the lifetime of the CPI process so each instance type
  # is queried at most once. 
  class InstanceTypeInfo
    def initialize(ec2_client, logger)
      @ec2_client = ec2_client
      @logger = logger
      @cache = {}
    end

    # Returns true if EBS volumes on this instance type are exposed exclusively via
    # NVMe and must be located using the /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_*
    # symlink. This is true only for Nitro instances (nvme_support = 'required').
    # Xen instances with NVMe instance storage (e.g. i3, nvme_support = 'supported')
    # still use traditional /dev/xvd* paths for EBS volumes.
    def ebs_requires_nvme_path?(instance_type)
      info = fetch(instance_type)
      return false if info.nil?

      info.ebs_info&.nvme_support == 'required'
    end

    # Returns true if instance storage (local NVMe SSDs) on this instance type uses
    # /dev/nvme*n1 device naming.
    # Returns true when nvme_support is 'required'.
    def instance_storage_nvme_naming?(instance_type)
      info = fetch(instance_type)
      return false if info.nil?

      info.instance_storage_info&.nvme_support == 'required'
    end

    private

    # Fetches and caches the DescribeInstanceTypes response for the given instance type.
    # Returns the instance type info struct, or nil if the type is unknown/invalid.
    def fetch(instance_type)
      instance_type = instance_type.nil? ? 'unspecified' : instance_type

      return @cache[instance_type] if @cache.key?(instance_type)

      result = query(instance_type)
      @cache[instance_type] = result
      result
    end

    def query(instance_type)
      @logger.debug("DescribeInstanceTypes for '#{instance_type}'")

      response = nil
      errors = [Aws::EC2::Errors::RequestLimitExceeded, Aws::EC2::Errors::InternalError, Aws::EC2::Errors::ServiceUnavailable]
      Bosh::Common.retryable(tries: 5, sleep: 1, on: errors) do |_tries, error|
        @logger.warn("DescribeInstanceTypes retrying for '#{instance_type}': #{error.message}") if error
        response = @ec2_client.describe_instance_types(
          instance_types: [instance_type],
        )
        true
      end

      if response.instance_types.empty?
        @logger.warn("DescribeInstanceTypes returned no data for '#{instance_type}'")
        return nil
      end

      response.instance_types.first
    rescue Aws::EC2::Errors::InvalidInstanceType, Aws::EC2::Errors::InvalidParameterValue => e
      @logger.warn("DescribeInstanceTypes failed for '#{instance_type}': #{e.message}")
      nil
    rescue Aws::Errors::ServiceError => e
      raise Bosh::Clouds::CloudError, "DescribeInstanceTypes API error for '#{instance_type}': #{e.message}"
    end
  end
end
