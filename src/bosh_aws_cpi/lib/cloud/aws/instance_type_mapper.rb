module Bosh::AwsCloud
  class InstanceTypeMapper

    SUPPORTED_VM_TYPES_SORTED_BY_PREFERENCE_ORDER = [
      { name: 't2.nano',     cpu: 1,  ram: 0.5 * 1024 },
      { name: 't2.micro',    cpu: 1,  ram: 1 * 1024 },
      { name: 't2.small',    cpu: 1,  ram: 2 * 1024 },
      { name: 'c5.large',    cpu: 2,  ram: 4 * 1024 },
      { name: 'm5.large',    cpu: 2,  ram: 8 * 1024 },
      { name: 'r5.large',    cpu: 2,  ram: 16 * 1024 },
      { name: 'c5.xlarge',   cpu: 4,  ram: 8 * 1024 },
      { name: 'm5.xlarge',   cpu: 4,  ram: 16 * 1024 },
      { name: 'r5.xlarge',   cpu: 4,  ram: 32 * 1024 },
      { name: 'c5.2xlarge',  cpu: 8,  ram: 16 * 1024 },
      { name: 'm5.2xlarge',  cpu: 8,  ram: 32 * 1024 },
      { name: 'r5.2xlarge',  cpu: 8,  ram: 64 * 1024 },
      { name: 'c5.4xlarge',  cpu: 16, ram: 32 * 1024 },
      { name: 'm5.4xlarge',  cpu: 16, ram: 64 * 1024 },
      { name: 'r5.4xlarge',  cpu: 16, ram: 128 * 1024 },
      { name: 'c5.9xlarge',  cpu: 36, ram: 72 * 1024 },
      { name: 'm5.8xlarge',  cpu: 32, ram: 128 * 1024 },
      { name: 'r5.8xlarge',  cpu: 32, ram: 256 * 1024 },
      { name: 'c5.12xlarge', cpu: 48, ram: 96 * 1024 },
      { name: 'm5.12xlarge', cpu: 48, ram: 192 * 1024 },
      { name: 'r5.12xlarge', cpu: 48, ram: 384 * 1024 },
      { name: 'm5.16xlarge', cpu: 64, ram: 256 * 1024 },
      { name: 'r5.16xlarge', cpu: 64, ram: 512 * 1024 }
    ]

    def initialize
    end

    def map(vm_properties)
      closest_match = SUPPORTED_VM_TYPES_SORTED_BY_PREFERENCE_ORDER.find do |type|
        type[:cpu] >= vm_properties['cpu'] && type[:ram] >= vm_properties['ram']
      end

      if closest_match.nil?
        largest_vm = SUPPORTED_VM_TYPES_SORTED_BY_PREFERENCE_ORDER.last
        raise "Unable to meet requested VM requirements: #{vm_properties['cpu']} CPU, #{vm_properties['ram']} RAM. " +
              "Largest known VM type is '#{largest_vm[:name]}': #{largest_vm[:cpu]} CPU, #{largest_vm[:ram]} RAM."
      end

      closest_match[:name]
    end
  end
end
