module Bosh::AwsCloud
  class InstanceTypeMapper

    SUPPORTED_VM_TYPES = [
      {name: 't2.nano',    cpu: 1,  ram: 0.5 * 1024},
      {name: 't2.micro',   cpu: 1,  ram: 1 * 1024},
      {name: 't2.small',   cpu: 1,  ram: 2 * 1024},
      {name: 'c4.large',   cpu: 2,  ram: 3.75 * 1024},
      {name: 'm4.large',   cpu: 2,  ram: 8 * 1024},
      {name: 'r3.large',   cpu: 2,  ram: 15.25 * 1024},
      {name: 'c4.xlarge',  cpu: 4,  ram: 7.5 * 1024},
      {name: 'm4.xlarge',  cpu: 4,  ram: 16 * 1024},
      {name: 'r3.xlarge',  cpu: 4,  ram: 30.5 * 1024},
      {name: 'c4.2xlarge', cpu: 8,  ram: 15 * 1024},
      {name: 'm4.2xlarge', cpu: 8,  ram: 32 * 1024},
      {name: 'r3.2xlarge', cpu: 8,  ram: 61 * 1024},
      {name: 'c4.4xlarge', cpu: 16, ram: 30 * 1024},
      {name: 'm4.4xlarge', cpu: 16, ram: 64 * 1024},
      {name: 'r3.4xlarge', cpu: 16, ram: 122 * 1024},
    ]

    def initialize
    end

    def map(vm_properties)
      possible_types = types_meeting_requirement(vm_properties)
      if possible_types.empty?
        largest_vm = SUPPORTED_VM_TYPES.last
        raise "Unable to meet requested VM requirements: #{vm_properties['cpu']} CPU, #{vm_properties['ram']} RAM. " +
              "Largest known VM type is '#{largest_vm[:name]}': #{largest_vm[:cpu]} CPU, #{largest_vm[:ram]} RAM."
      end

      closest_match = possible_types.min_by do |type|
        [type[:cpu], type[:ram]]
      end

      closest_match[:name]
    end

    private

    def types_meeting_requirement(vm_properties)
      SUPPORTED_VM_TYPES.select do |type|
        type[:cpu] >= vm_properties['cpu'] && type[:ram] >= vm_properties['ram']
      end
    end
  end
end
