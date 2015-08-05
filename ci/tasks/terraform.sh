#!/usr/bin/env bash

set -e -x

source bosh-cpi-release/ci/tasks/utils.sh

check_param aws_access_key_id
check_param aws_secret_access_key
check_param concourse_ip
check_param base_os
check_param security_group_trusted_ip

# generates a plan
/terraform/terraform plan -out=${base_os}-bats.tfplan \
  -var "access_key=${aws_access_key_id}" \
  -var "secret_key=${aws_secret_access_key}" \
  -var "build_id=bats-${base_os}" \
  -var "concourse_ip=${concourse_ip}" \
  -var "security_group_trusted_ip=${security_group_trusted_ip}" \
  bosh-cpi-release/ci

state_file=${base_os}-bats.tfstate
export_file=terraform-${base_os}-exports.sh

# applies the plan, generates a state file
/terraform/terraform apply -state=$state_file ${base_os}-bats.tfplan

# exports values into an exports file
echo -e "#!/usr/bin/env bash" >> $export_file
echo -e "export DIRECTOR=$(/terraform/terraform output -state=${state_file} director_vip)" >> $export_file
echo -e "export VIP=$(/terraform/terraform output -state=${state_file} bats_vip)" >> $export_file
echo -e "export SUBNET_ID=$(/terraform/terraform output -state=${state_file} subnet_id)" >> $export_file
echo -e "export SECURITY_GROUP_NAME=$(/terraform/terraform output -state=${state_file} security_group_name)" >> $export_file
echo -e "export AVAILABILITY_ZONE=$(/terraform/terraform output -state=${state_file} availability_zone)" >> $export_file
