# Copyright (c) 2009-2012 VMware, Inc.

require "spec_helper"

describe Bosh::AwsCloud::Cloud do

  it "gets volume ids" do
    fake_instance_id = "fakeinstance"

    cloud = mock_cloud do |ec2, region|
      mock_instance = double("AWS Instance")
      expect(ec2).to receive(:instance).with(fake_instance_id).and_return(mock_instance)
      expect(mock_instance).to receive(:block_device_mappings).and_return([
        double("device1",
          :device_name => "/dev/sda2",
          :ebs => double(Aws::AutoScaling::Types::Ebs,
            :volume_id => "vol-123",
            :status => "attaching",
            :attach_time => 'time',
            :delete_on_termination => true
          )
        ),
        double("device2",
          :device_name => "/dev/sdb",
          :virtual_name => "ephemeral0",
          :ebs => nil,
        ),
        double("device3",
          :device_name => "/dev/sdb2",
          :ebs => double(Aws::AutoScaling::Types::Ebs,
            :volume_id => "vol-456",
            :status => "attaching",
            :attach_time => 'time',
            :delete_on_termination => true
          )
        )
      ])
    end

    expect(cloud.get_disks(fake_instance_id)).to eq(["vol-123", "vol-456"])
  end

end
