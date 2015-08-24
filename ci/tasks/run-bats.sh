#!/usr/bin/env bash

set -e

source bosh-cpi-release/ci/tasks/utils.sh

check_param base_os
check_param private_key_data
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

source terraform-exports/terraform-${base_os}-exports.sh

mkdir -p $PWD/keys
echo "$private_key_data" > $PWD/keys/bats.pem
eval $(ssh-agent)
chmod go-r $PWD/keys/bats.pem
ssh-add $PWD/keys/bats.pem

export BAT_DIRECTOR=$DIRECTOR
export BAT_DNS_HOST=$DIRECTOR
export BAT_STEMCELL="${PWD}/stemcell/stemcell.tgz"
export BAT_DEPLOYMENT_SPEC="${PWD}/${base_os}-bats-config.yml"
export BAT_INFRASTRUCTURE=aws
export BAT_NETWORKING=manual
export BAT_VIP=$VIP
export BAT_SUBNET_ID=$SUBNET_ID
export BAT_SECURITY_GROUP_NAME=$SECURITY_GROUP_NAME
export BAT_VCAP_PRIVATE_KEY=$PWD/keys/bats.pem

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

cat $BAT_DEPLOYMENT_SPEC # todo: do not cat out the deployment spec

#cd bats
#bundle install
#bundle exec rspec spec
exit 0
