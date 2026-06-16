require 'spec_helper'

module Bosh::AwsCloud
  describe StaticInstanceTypeInfo do
    subject(:info) { StaticInstanceTypeInfo.new }

    describe '#ebs_requires_nvme_path?' do
      context 'Nitro instance families' do
        %w[c5.xlarge m5.large r5.2xlarge t3.micro a1.medium g5.xlarge i3en.large i4i.xlarge m6i.large].each do |type|
          it "returns true for #{type}" do
            expect(info.ebs_requires_nvme_path?(type)).to be true
          end
        end
      end

      context 'Xen/legacy instance families' do
        %w[m3.xlarge c3.large r3.2xlarge i2.xlarge d2.xlarge m1.small i3.xlarge].each do |type|
          it "returns false for #{type}" do
            expect(info.ebs_requires_nvme_path?(type)).to be false
          end
        end
      end

      it 'returns false for nil' do
        expect(info.ebs_requires_nvme_path?(nil)).to be false
      end

      it 'returns false for an unknown instance type' do
        expect(info.ebs_requires_nvme_path?('unknown.xlarge')).to be false
      end
    end

    describe '#instance_storage_nvme_naming?' do
      context 'instance families with NVMe local storage' do
        %w[i3.xlarge i3en.large i4i.xlarge m6id.large c6id.xlarge r6id.2xlarge z1d.large c5d.xlarge m5d.large].each do |type|
          it "returns true for #{type}" do
            expect(info.instance_storage_nvme_naming?(type)).to be true
          end
        end
      end

      context 'instance families without NVMe local storage or Xen HDD/SSD' do
        %w[m3.xlarge i2.xlarge d2.xlarge x1.16xlarge c3.large r3.large].each do |type|
          it "returns false for #{type}" do
            expect(info.instance_storage_nvme_naming?(type)).to be false
          end
        end
      end

      context 'Nitro instance families without local storage' do
        # These are Nitro (EBS NVMe) but have no local storage — instance_storage_nvme_naming? must be false
        %w[m5.large c5.xlarge r5.2xlarge t3.micro].each do |type|
          it "returns false for #{type} (no local storage)" do
            expect(info.instance_storage_nvme_naming?(type)).to be false
          end
        end
      end

      it 'returns false for nil' do
        expect(info.instance_storage_nvme_naming?(nil)).to be false
      end

      it 'returns false for an unknown instance type' do
        expect(info.instance_storage_nvme_naming?('unknown.xlarge')).to be false
      end
    end
  end
end
