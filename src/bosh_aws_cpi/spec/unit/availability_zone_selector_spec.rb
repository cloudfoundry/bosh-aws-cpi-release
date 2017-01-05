require "spec_helper"

describe Bosh::AwsCloud::AvailabilityZoneSelector do

  let(:instance) { instance_double(Aws::EC2::Instance) }
  let(:resource) { double(Aws::EC2::Resource, client: client) }
  let(:client) { double(Aws::EC2::Client) }
  let(:subject) { described_class.new(resource) }

  describe '#common_availability_zone' do
    it 'should raise an error when multiple availability zones are present and volume information is passed in' do
      expect {
        subject.common_availability_zone(%w[this_zone that_zone], 'other_zone', 'another_zone')
      }.to raise_error Bosh::Clouds::CloudError, "can't use multiple availability zones: subnet in another_zone, VM in other_zone, and volume in this_zone, that_zone"
    end

    it 'should raise an error when multiple availability zones are present and no volume information is passed in' do
      expect {
        subject.common_availability_zone([], 'other_zone', 'another_zone')
      }.to raise_error Bosh::Clouds::CloudError, "can't use multiple availability zones: subnet in another_zone, VM in other_zone"
    end

    it 'should select the common availability zone' do
      expect(subject.common_availability_zone(%w(this_zone), 'this_zone', nil)).to eq('this_zone')
    end
  end

  describe '#select_availability_zone' do
    context 'without a default' do
      let(:subject) { described_class.new(resource) }

      context 'with a instance id' do
        it 'should return the az of the instance' do
          allow(resource).to receive(:instance).with('fake-instance-id').and_return(instance)
          allow(instance).to receive(:placement).and_return(double('placement', availability_zone: 'fake-vm-az'))

          expect(subject.select_availability_zone('fake-instance-id')).to eq('fake-vm-az')
        end
      end

      context 'without a instance id' do
        it 'should return a random az' do
          allow(client).to receive(:describe_availability_zones).and_return({
            'availability_zones' => [{'zone_name' => 'fake-random-az'}],
          })

          allow(Random).to receive_messages(:rand => 0)
          expect(subject.select_availability_zone(nil)).to eq('fake-random-az')
        end
      end
    end
  end
end
