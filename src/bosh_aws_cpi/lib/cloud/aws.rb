module Bosh
  module AwsCloud; end
end

require "aws-sdk"
require "httpclient"
require "pp"
require "set"
require "tmpdir"
require "securerandom"
require "json"

require "common/exec"
require "common/thread_pool"
require "common/thread_formatter"

require "bosh/cpi/registry_client"

require "cloud"
require "cloud/aws/helpers"
require "cloud/aws/cloud"

require "cloud/aws/aki_picker"
require "cloud/aws/network_configurator"
require "cloud/aws/network"
require "cloud/aws/stemcell"
require "cloud/aws/stemcell_creator"
require "cloud/aws/dynamic_network"
require "cloud/aws/manual_network"
require "cloud/aws/vip_network"
require "cloud/aws/instance_manager"
require "cloud/aws/instance"
require "cloud/aws/spot_manager"
require "cloud/aws/tag_manager"
require "cloud/aws/availability_zone_selector"
require "cloud/aws/resource_wait"
require "cloud/aws/volume_properties"
require "cloud/aws/instance_param_mapper"
require "cloud/aws/security_group_mapper"
require "cloud/aws/block_device_manager"
require "cloud/aws/instance_type_mapper"
require "cloud/aws/sdk_helpers/volume_attachment"

module Bosh
  module Clouds
    Aws = Bosh::AwsCloud::Cloud
  end
end
