module Bosh::AwsCloud
  class SecurityGroupMapper
    def initialize(ec2_client)
      @ec2_client = ec2_client
    end

    def map_to_ids(inputs, target_subnet_id)
      return nil if (inputs || []).empty?
      return nil if target_subnet_id.nil?

      existing_groups = nil
      inputs.map do |input|
        if is_id?(input)
          input
        else
          existing_groups ||= existing_groups_for_subnet(target_subnet_id)
          convert_to_id(input, existing_groups)
        end
      end
    end

    private

    def convert_to_id(input, existing_groups)
      found = existing_groups.select { |group| group.group_name == input }

      if found.empty?
        raise Bosh::Clouds::CloudError, "Security group not found with name '#{input}'"
      end

      if found.length > 1
        sg_ids = found.map(&:id)
        raise Bosh::Clouds::CloudError, "Found multiple matching security groups with name '#{input}': #{sg_ids.join(', ')}"
      end

      found.first.id
    end

    def existing_groups_for_subnet(subnet_id)
      # NOTE: We call #to_a to ensure the EC2 client makes a single request.
      @ec2_client.subnet(subnet_id).vpc.security_groups.to_a
    end

    def is_id?(input)
      input =~ /^sg-[a-z0-9]{8}/
    end
  end
end
