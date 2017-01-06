require "spec_helper"

module Bosh::AwsCloud
  describe SecurityGroupMapper do
    let(:security_group_mapper) { SecurityGroupMapper.new(ec2_resource) }
    let(:ec2_resource) { instance_double(Aws::EC2::Resource) }
    let(:security_groups) do
      [
        instance_double(Aws::EC2::SecurityGroup, group_name: 'valid-sg0', id: 'sg-00000000'),
        instance_double(Aws::EC2::SecurityGroup, group_name: 'valid-sg1', id: 'sg-11111111')
      ]
    end
    let(:target_subnet_id) { 'fake-subnet-id' }
    let(:subnet) do
      instance_double(Aws::EC2::Subnet,
        id: target_subnet_id,
        vpc: instance_double(Aws::EC2::Vpc, security_groups: security_groups),
      )
    end

    before do
      allow(ec2_resource).to receive(:subnet).with(target_subnet_id).and_return(subnet)
    end

    describe '#map' do
      context 'given nil input' do
        it 'returns nil' do
          expect(security_group_mapper.map_to_ids(nil, nil)).to be_nil
        end
      end

      context 'given empty input' do
        it 'returns nil' do
          expect(security_group_mapper.map_to_ids([], nil)).to be_nil
        end
      end

      context 'given input as a list of security groups as IDs' do
        it 'returns the security group IDs' do
          expect(ec2_resource).to_not receive(:subnets)
          expect(security_group_mapper.map_to_ids(['sg-00000000', 'sg-11111111'], target_subnet_id))
            .to eq(['sg-00000000', 'sg-11111111'])
        end
      end

      context 'given input as a list of security groups, including names' do
        it 'returns the security group IDs' do
          expect(security_group_mapper.map_to_ids(['sg-00000000', 'valid-sg1'], target_subnet_id))
            .to eq(['sg-00000000', 'sg-11111111'])
        end

        context 'when an invalid security group is provided' do
          it 'raises an error' do
            expect {
              security_group_mapper.map_to_ids(['valid-sg1', 'bogus-sg'], target_subnet_id)
            }.to raise_error Bosh::Clouds::CloudError, /bogus-sg/
          end
        end

        context 'when provided name matches multiple groups' do
          let(:ec2_groups) do
            [
              instance_double('Aws::EC2::SecurityGroup', name: 'duplicate-name', id: 'sg-00000000'),
              instance_double('Aws::EC2::SecurityGroup', name: 'duplicate-name', id: 'sg-11111111')
            ]
          end
          it 'raises an error' do
            expect {
              security_group_mapper.map_to_ids(['duplicate-name'], target_subnet_id)
            }.to raise_error Bosh::Clouds::CloudError, /duplicate-name/
          end
        end
      end
    end
  end
end
