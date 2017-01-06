# Copyright (c) 2009-2012 VMware, Inc.

require "spec_helper"

describe Bosh::AwsCloud::Cloud do

  before(:each) do
    @registry = mock_registry
  end

  it "detaches EC2 volume from an instance" do
    instance = double("instance", :id => "i-test")
    volume = double("volume", :id => "v-foobar", :exists? => true, :state => 'available')
    attachment = double("attachment", :device => "/dev/sdf")

    cloud = mock_cloud do |ec2|
      allow(ec2).to receive(:instance).with("i-test").and_return(instance)
      allow(ec2).to receive(:volume).with("v-foobar").and_return(volume)
    end

    mappings = [
      double("disk1", device_name: "/dev/sdf", ebs: double("volume", :volume_id => "v-foobar")),
      double("disk2", device_name: "/dev/sdg", ebs: double("volume", :volume_id => "v-deadbeef")),
    ]

    expect(instance).to receive(:block_device_mappings).and_return(mappings)

    expect(volume).to receive(:detach_from_instance).
      with(instance_id: 'i-test', device: "/dev/sdf", force: false).and_return(attachment)

    allow(Bosh::AwsCloud::SdkHelpers::VolumeAttachment).to receive(:new).and_return(attachment)

    allow(Bosh::AwsCloud::ResourceWait).to receive(:for_attachment).with(attachment: attachment, state: 'detached')

    old_settings = {
      "foo" => "bar",
      "disks" => {
        "persistent" => {
          "v-foobar" => "/dev/sdf",
          "v-deadbeef" => "/dev/sdg"
        }
      }
    }

    new_settings = {
      "foo" => "bar",
      "disks" => {
        "persistent" => {
          "v-deadbeef" => "/dev/sdg"
        }
      }
    }

    expect(@registry).to receive(:read_settings).
      with("i-test").
      and_return(old_settings)

    expect(@registry).to receive(:update_settings).with("i-test", new_settings)

    cloud.detach_disk("i-test", "v-foobar")
  end

  it "bypasses the detaching process when volume is missing" do
    instance = double("instance", :id => "i-test")
    volume = double("volume", :id => "non-exist-volume-id")

    cloud = mock_cloud do |ec2|
      allow(ec2).to receive(:instance).with("i-test").and_return(instance)
      allow(ec2).to receive(:volume).with("non-exist-volume-id").and_return(volume)
    end

    old_settings = {
      "foo" => "bar",
      "disks" => {
        "persistent" => {
          "non-exist-volume-id" => "/dev/sdf",
          "exist-volume-id" => "/dev/sdg"
        }
      }
    }

    new_settings = {
      "foo" => "bar",
      "disks" => {
        "persistent" => {
          "exist-volume-id" => "/dev/sdg"
        }
      }
    }

    expect(@registry).to receive(:read_settings).
      with("i-test").
      and_return(old_settings)

    expect(@registry).to receive(:update_settings).with("i-test", new_settings)

    allow(volume).to receive(:state).and_raise(Aws::EC2::Errors::InvalidVolumeNotFound.new(nil, 'not-found'))

    expect {
      cloud.detach_disk("i-test", "non-exist-volume-id")
    }.to_not raise_error
  end
end
