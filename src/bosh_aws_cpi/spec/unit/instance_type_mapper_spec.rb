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
      medium_vm => 'm5.large',
      large_vm => 'c5.2xlarge',
    }

    output_map.each do |input, expected_output|
      expect(subject.map(input)).to eq(expected_output)
    end
  end

  it 'chooses the instance type by preference order' do
    # Previously we found the instance type based off of the minimal match of CPU, then minimal match of RAM.
    # For 32 CPU and 64GB of RAM, this normally would have chosen m5.8xlarge. However, the c5.9xlarge is a
    # closer match that costs less.
    expect(subject.map({ 'ram' => 64, 'cpu' => 32 })).to eq('c5.9xlarge')
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
