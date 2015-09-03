#!/usr/bin/env bash

set -e

source bosh-cpi-release/ci/tasks/utils.sh

check_param base_os
check_param aws_access_key_id
check_param aws_secret_access_key
check_param region_name
check_param BAT_VCAP_PASSWORD
check_param BAT_SECOND_STATIC_IP
check_param BAT_NETWORK_CIDR
check_param BAT_NETWORK_RESERVED_RANGE
check_param BAT_NETWORK_STATIC_RANGE
check_param BAT_NETWORK_GATEWAY
check_param BAT_NETWORK_STATIC_IP
check_param BAT_STEMCELL_NAME

source /etc/profile.d/chruby.sh
chruby 2.1.2

export AWS_ACCESS_KEY_ID=${aws_access_key_id}
export AWS_SECRET_ACCESS_KEY=${aws_secret_access_key}
export AWS_DEFAULT_REGION=${region_name}

stack_name="aws-cpi-stack"
stack_info=$(get_stack_info $stack_name)

DIRECTOR=$(get_stack_info_of "${stack_info}" "${base_os}directorvip")
VIP=$(get_stack_info_of "${stack_info}" "${base_os}batsvip")
SUBNET_ID=$(get_stack_info_of "${stack_info}" "${base_os}subnetid")
sg_id=$(get_stack_info_of "${stack_info}" "securitygroupid")
SECURITY_GROUP_NAME=$(aws ec2 describe-security-groups --group-ids ${sg_id} | jq -r '.SecurityGroups[] .GroupName')
AVAILABILITY_ZONE=$(get_stack_info_of "${stack_info}" "${base_os}availabilityzone")

eval $(ssh-agent)
private_key=${PWD}/setup-director/deployment/bats.pem
ssh-add ${private_key}

export BAT_DIRECTOR=$DIRECTOR
export BAT_DNS_HOST=$DIRECTOR
export BAT_STEMCELL="${PWD}/stemcell/stemcell.tgz"
export BAT_DEPLOYMENT_SPEC="${PWD}/${base_os}-bats-config.yml"
export BAT_INFRASTRUCTURE=aws
export BAT_NETWORKING=manual
export BAT_VIP=$VIP
export BAT_SUBNET_ID=$SUBNET_ID
export BAT_SECURITY_GROUP_NAME=$SECURITY_GROUP_NAME
export BAT_VCAP_PRIVATE_KEY=${private_key}

bosh -n target $BAT_DIRECTOR

cat > "${BAT_DEPLOYMENT_SPEC}" <<EOF
---
cpi: aws
properties:
  vip: $BAT_VIP
  second_static_ip: $BAT_SECOND_STATIC_IP
  uuid: $(bosh status --uuid)
  pool_size: 1
  stemcell:
    name: ${BAT_STEMCELL_NAME}
    version: latest
  instances: 1
  key_name:  bats
  networks:
    - name: default
      static_ip: $BAT_NETWORK_STATIC_IP
      type: manual
      cidr: $BAT_NETWORK_CIDR
      reserved: [$BAT_NETWORK_RESERVED_RANGE]
      static: [$BAT_NETWORK_STATIC_RANGE]
      gateway: $BAT_NETWORK_GATEWAY
      subnet: $BAT_SUBNET_ID
      security_groups: [$BAT_SECURITY_GROUP_NAME]
EOF

cd bats
./write_gemfile
bundle install
bundle exec rspec spec
