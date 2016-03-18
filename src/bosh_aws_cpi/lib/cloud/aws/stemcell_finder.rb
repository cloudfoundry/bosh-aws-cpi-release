require 'cloud/aws/light_stemcell'
require 'cloud/aws/stemcell'

module Bosh::AwsCloud
  class StemcellFinder
    def self.find_by_id(client, id)
      regex = / light$/

      if id =~ regex
        LightStemcell.new(Stemcell.find(client, id.sub(regex, '')), Bosh::Clouds::Config.logger)
      else
        Stemcell.find(client, id)
      end
    end
  end
end
