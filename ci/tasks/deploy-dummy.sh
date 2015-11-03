#!/usr/bin/env bash

set -e

source bosh-cpi-release/ci/tasks/utils.sh

check_param base_os
check_param aws_access_key_id
check_param aws_secret_access_key
check_param region_name
check_param stemcell_name
check_param stack_name
check_param director_username
check_param director_password

source /etc/profile.d/chruby.sh
chruby 2.1.2

export AWS_ACCESS_KEY_ID=${aws_access_key_id}
export AWS_SECRET_ACCESS_KEY=${aws_secret_access_key}
export AWS_DEFAULT_REGION=${region_name}

cpi_release_name="bosh-aws-cpi"
stack_info=$(get_stack_info $stack_name)

stack_prefix=${base_os}
SUBNET_ID=$(get_stack_info_of "${stack_info}" "${stack_prefix}SubnetID")
AVAILABILITY_ZONE=$(get_stack_info_of "${stack_info}" "${stack_prefix}AvailabilityZone")
DIRECTOR_IP=$(get_stack_info_of "${stack_info}" "${stack_prefix}DirectorEIP")
IAM_INSTANCE_PROFILE=$(get_stack_info_of "${stack_info}" "End2EndIAMInstanceProfile")

bosh -n target ${DIRECTOR_IP}
bosh login ${director_username} ${director_password}

cat > dummy-manifest.yml <<EOF
---
name: dummy
director_uuid: $(bosh status --uuid)

releases:
  - name: dummy
    version: latest

compilation:
  reuse_compilation_vms: true
  workers: 1
  network: private
  cloud_properties:
    instance_type: m3.medium
    availability_zone: ${AVAILABILITY_ZONE}

update:
  canaries: 1
  canary_watch_time: 30000-240000
  update_watch_time: 30000-600000
  max_in_flight: 3

resource_pools:
  - name: default
    stemcell:
      name: ${stemcell_name}
      version: latest
    network: private
    cloud_properties:
      instance_type: m3.medium
      availability_zone: ${AVAILABILITY_ZONE}

networks:
  - name: private
    type: dynamic
    cloud_properties: {subnet: ${SUBNET_ID}}

jobs:
  - name: dummy
    template: dummy
    instances: 1
    resource_pool: default
    networks:
      - name: private
        default: [dns, gateway]
EOF

git clone https://github.com/pivotal-cf-experimental/dummy-boshrelease.git

pushd dummy-boshrelease
  bosh -n create release --force
  bosh -n upload release --skip-if-exists
popd

bosh -n upload stemcell stemcell/stemcell.tgz --skip-if-exists

bosh -d dummy-manifest.yml -n deploy

bosh -n delete deployment dummy

bosh -n cleanup --all
