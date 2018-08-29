module Bosh::AwsCloud
  class RegistryDisabledClient
    def update_settings(instance_id, _)
      raise Bosh::Clouds::CloudError, "An attempt to update registry settings has failed for " \
                                      "instance_id=#{instance_id}. The registry is disabled."
    end

    def read_settings(instance_id)
      raise Bosh::Clouds::CloudError, "An attempt to read registry settings has failed for " \
                                      "instance_id=#{instance_id}. The registry is disabled."
    end

    def delete_settings(instance_id)
      raise Bosh::Clouds::CloudError, "An attempt to delete registry settings has failed for " \
                                      "instance_id=#{instance_id}. The registry is disabled."
    end
  end
end