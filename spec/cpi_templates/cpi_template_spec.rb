require 'spec_helper'

describe 'CPI' do
  let(:yaml_template) {
    File.expand_path('./jobs/cpi/templates/cpi.yml.erb')
  }
  let(:json_template) {
    File.expand_path('./jobs/cpi/templates/cpi.json.erb')
  }

  context 'generated json and yaml configuration files' do
    it 'should be equal while exercising fixture 1' do
      exercise_fixture('./spec/fixture/spec_cpi_1.yml', yaml_template, json_template)
    end

    it 'should be equal while exercising fixture 2' do
      exercise_fixture('./spec/fixture/spec_cpi_2.yml', yaml_template, json_template)
    end

    it 'should be equal while exercising fixture 3' do
      exercise_fixture('./spec/fixture/spec_cpi_3.yml', yaml_template, json_template)
    end
  end
end