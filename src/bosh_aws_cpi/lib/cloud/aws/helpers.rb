module Bosh::AwsCloud

  module Helpers
    def default_ephemeral_disk_mapping
       [
         {
           :device_name => '/dev/sdb',
           :virtual_name => 'ephemeral0',
         },
       ]
    end

    ##
    # Raises CloudError exception
    #
    def cloud_error(message)
      if @logger
        @logger.error(message)
      end
      raise Bosh::Clouds::CloudError, message
    end

  end
end
