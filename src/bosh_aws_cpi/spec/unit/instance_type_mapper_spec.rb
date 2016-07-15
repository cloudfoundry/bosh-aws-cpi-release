require 'spec_helper'

describe Bosh::AwsCloud::InstanceTypeMapper do
  subject { described_class.new }

  it 'maps ram and cpu to a specific instance type' do
    tiny_vm = {
      'ram' => 128,
      'cpu' => 1,
    }
    medium_vm = {
      'ram' => 8 * 1024,
      'cpu' => 2,
    }
    large_vm = {
      'ram' => 12 * 1024,
      'cpu' => 8,
    }
    output_map = {
      tiny_vm => 't2.nano',
      medium_vm => 'm4.large',
      large_vm => 'c4.2xlarge',
    }

    output_map.each do |input, expected_output|
      expect(subject.map(input)).to eq(expected_output)
    end
  end

  it 'raises an error if no match is found' do
    too_large_vm = {
      'cpu' => 3200,
      'ram' => 102400,
    }
    expect {
      expect(subject.map(too_large_vm))
    }.to raise_error(/Unable to meet requested VM requirements:.*3200 CPU.*102400 RAM/)
  end
end
