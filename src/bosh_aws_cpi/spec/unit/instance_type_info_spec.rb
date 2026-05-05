require 'spec_helper'

module Bosh::AwsCloud
  describe InstanceTypeInfo do
    let(:logger) { Logger.new('/dev/null') }
    let(:ec2_client) { instance_double(Aws::EC2::Client) }
    let(:instance_type_info) { InstanceTypeInfo.new(ec2_client, logger) }

    def stub_nvme_support(instance_type, nvme_support)
      allow(ec2_client).to receive(:describe_instance_types).with(
        instance_types: [instance_type],
      ).and_return(
        double(instance_types: [
          double(ebs_info: double(nvme_support: nvme_support)),
        ])
      )
    end

    def stub_unknown_instance_type(instance_type)
      allow(ec2_client).to receive(:describe_instance_types).with(
        instance_types: [instance_type],
      ).and_return(double(instance_types: []))
    end

    describe '#ebs_requires_nvme_path?' do
      context 'when nvme_support is required (Nitro, e.g. c5.xlarge)' do
        before { stub_nvme_support('c5.xlarge', 'required') }

        it 'returns true' do
          expect(instance_type_info.ebs_requires_nvme_path?('c5.xlarge')).to be true
        end

        it 'caches the API result (calls API only once for repeated queries)' do
          instance_type_info.ebs_requires_nvme_path?('c5.xlarge')
          instance_type_info.ebs_requires_nvme_path?('c5.xlarge')
          expect(ec2_client).to have_received(:describe_instance_types).once
        end
      end

      context 'when nvme_support is supported (Xen with NVMe instance storage, e.g. i3.xlarge)' do
        before { stub_nvme_support('i3.xlarge', 'supported') }

        it 'returns false because EBS on i3 uses traditional xvd paths, not NVMe by-id' do
          expect(instance_type_info.ebs_requires_nvme_path?('i3.xlarge')).to be false
        end
      end

      context 'when nvme_support is unsupported (legacy Xen, e.g. m3.xlarge)' do
        before { stub_nvme_support('m3.xlarge', 'unsupported') }

        it 'returns false' do
          expect(instance_type_info.ebs_requires_nvme_path?('m3.xlarge')).to be false
        end
      end
    end

    describe '#instance_storage_nvme_naming?' do
      context 'when nvme_support is required (Nitro, e.g. c5d.xlarge)' do
        before { stub_nvme_support('c5d.xlarge', 'required') }

        it 'returns true because instance storage uses /dev/nvme*n1 naming' do
          expect(instance_type_info.instance_storage_nvme_naming?('c5d.xlarge')).to be true
        end
      end

      context 'when nvme_support is supported (Xen with NVMe instance storage, e.g. i3.xlarge)' do
        before { stub_nvme_support('i3.xlarge', 'supported') }

        it 'returns true because i3 local disks appear as /dev/nvme*n1' do
          expect(instance_type_info.instance_storage_nvme_naming?('i3.xlarge')).to be true
        end

        it 'caches the API result' do
          instance_type_info.instance_storage_nvme_naming?('i3.xlarge')
          instance_type_info.instance_storage_nvme_naming?('i3.xlarge')
          expect(ec2_client).to have_received(:describe_instance_types).once
        end
      end

      context 'when nvme_support is unsupported (legacy Xen, e.g. m3.xlarge)' do
        before { stub_nvme_support('m3.xlarge', 'unsupported') }

        it 'returns false' do
          expect(instance_type_info.instance_storage_nvme_naming?('m3.xlarge')).to be false
        end
      end
    end

    describe 'error handling and edge cases' do
      context 'when instance type is nil' do
        before { stub_unknown_instance_type('unspecified') }

        it 'ebs_requires_nvme_path? returns false' do
          expect(instance_type_info.ebs_requires_nvme_path?(nil)).to be false
        end

        it 'instance_storage_nvme_naming? returns false' do
          expect(instance_type_info.instance_storage_nvme_naming?(nil)).to be false
        end
      end

      context 'when instance type is unknown to AWS' do
        before { stub_unknown_instance_type('unknown.xlarge') }

        it 'ebs_requires_nvme_path? returns false' do
          expect(instance_type_info.ebs_requires_nvme_path?('unknown.xlarge')).to be false
        end

        it 'instance_storage_nvme_naming? returns false' do
          expect(instance_type_info.instance_storage_nvme_naming?('unknown.xlarge')).to be false
        end
      end

      context 'when API returns InvalidInstanceType error' do
        before do
          allow(ec2_client).to receive(:describe_instance_types).and_raise(
            Aws::EC2::Errors::InvalidInstanceType.new(nil, 'Invalid instance type')
          )
        end

        it 'ebs_requires_nvme_path? returns false' do
          expect(instance_type_info.ebs_requires_nvme_path?('bad.type')).to be false
        end

        it 'instance_storage_nvme_naming? returns false' do
          expect(instance_type_info.instance_storage_nvme_naming?('bad.type')).to be false
        end
      end

      context 'when API returns a transient error then succeeds' do
        before do
          call_count = 0
          allow(ec2_client).to receive(:describe_instance_types) do
            call_count += 1
            if call_count == 1
              raise Aws::EC2::Errors::RequestLimitExceeded.new(nil, 'Rate exceeded')
            end
            double(instance_types: [
              double(ebs_info: double(nvme_support: 'required')),
            ])
          end
        end

        it 'retries and returns the correct result' do
          expect(instance_type_info.ebs_requires_nvme_path?('c5.xlarge')).to be true
          expect(ec2_client).to have_received(:describe_instance_types).twice
        end
      end

      context 'when API returns a persistent service error' do
        before do
          allow(ec2_client).to receive(:describe_instance_types).and_raise(
            Aws::Errors::ServiceError.new(nil, 'Service unavailable')
          )
        end

        it 'raises CloudError for ebs_requires_nvme_path?' do
          expect { instance_type_info.ebs_requires_nvme_path?('c5.xlarge') }
            .to raise_error(Bosh::Clouds::CloudError, /DescribeInstanceTypes API error/)
        end

        it 'raises CloudError for instance_storage_nvme_naming?' do
          expect { instance_type_info.instance_storage_nvme_naming?('c5.xlarge') }
            .to raise_error(Bosh::Clouds::CloudError, /DescribeInstanceTypes API error/)
        end
      end
    end
  end
end

