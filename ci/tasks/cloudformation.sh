#!/usr/bin/env bash

set -e -x

source bosh-cpi-release/ci/tasks/utils.sh

check_param aws_access_key_id
check_param aws_secret_access_key
check_param region_name
check_param base_os

export AWS_ACCESS_KEY_ID=${aws_access_key_id}
export AWS_SECRET_ACCESS_KEY=${aws_secret_access_key}
export AWS_DEFAULT_REGION=${region_name}

export_file=cloudformation-${base_os}-exports.sh
stack_name="aws-cpi-stack"

aws cloudformation create-stack \
    --stack-name      ${stack_name} \
    --template-body   file:///${PWD}/bosh-cpi-release/ci/assets/cloudformation.template

stack_status=$(aws cloudformation describe-stacks --stack-name ${stack_name} | jq '.Stacks[].StackStatus')
desired_status="\"CREATE_COMPLETE\""
timeout=0
while [ "$desired_status" != "$stack_status" ] && [ "$timeout" -lt 300 ]
do
  stack_status=$(aws cloudformation describe-stacks --stack-name ${stack_name} | jq '.Stacks[].StackStatus')
  echo "waiting for StackStatus to == \"CREATE_COMPLETE\""
  sleep 20s
  timeout=$((timeout + 20))
done

aws cloudformation describe-stacks --stack-name ${stack_name} > cloudformation_state.json

# exports values into an exports file
echo -e "#!/usr/bin/env bash" >> $export_file
echo -e "export DIRECTOR=$(jq '.Stacks[].Outputs[] | select(.OutputKey=="\($base_os)directorvip").OutputValue' cloudformation_state.json --arg base_os ${base_os})" >> $export_file
echo -e "export VIP=$(jq '.Stacks[].Outputs[] | select(.OutputKey=="\($base_os)batsvip").OutputValue' cloudformation_state.json --arg base_os ${base_os})" >> $export_file
echo -e "export SUBNET_ID=$(jq '.Stacks[].Outputs[] | select(.OutputKey=="\($base_os)subnetid").OutputValue' cloudformation_state.json --arg base_os ${base_os}))" >> $export_file
echo -e "export SECURITY_GROUP_NAME=$(jq '.Stacks[].Outputs[] | select(.OutputKey=="securitygroupname").OutputValue' cloudformation_state.json))" >> $export_file
echo -e "export AVAILABILITY_ZONE=$(jq '.Stacks[].Outputs[] | select(.OutputKey=="\($base_os)availabilityzone").OutputValue' cloudformation_state.json --arg base_os ${base_os}))" >> $export_file
