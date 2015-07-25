require_relative './helpers/erb_template.rb'
require_relative './helpers/renderer.rb'

require 'yaml'

class Hash
  def sort_by_key(recursive = false, &block)
    self.keys.sort(&block).reduce({}) do |seed, key|
      seed[key] = self[key]
      if recursive && seed[key].is_a?(Hash)
        seed[key] = seed[key].sort_by_key(true, &block)
      end
      seed
    end
  end
end

def load_fixture(file)
  YAML.load_file(file)
end

def exercise_fixture(fixture_file, yaml_template, json_template)
  spec=load_fixture(fixture_file)
  yaml_hash=YAML.load(Renderer.render(spec, yaml_template))
  json_hash= JSON.parse(Renderer.render(spec, json_template))
  expect(yaml_hash.sort_by_key(true)).to eq(json_hash.sort_by_key(true))
end

RSpec.configure do |config|

end
