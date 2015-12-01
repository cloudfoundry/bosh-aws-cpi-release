#!/usr/bin/env bash

set -e

source bosh-cpi-src/ci/tasks/utils.sh

check_param aws_access_key_id
check_param aws_secret_access_key
check_param region_name
check_param stack_name

export AWS_ACCESS_KEY_ID=${aws_access_key_id}
export AWS_SECRET_ACCESS_KEY=${aws_secret_access_key}
export AWS_DEFAULT_REGION=${region_name}

stack_info=$(get_stack_info $stack_name)
vpc_id=$(get_stack_info_of "$stack_info" "VPCID")

if [ ! -z "${vpc_id}" ] ; then
  found_instances=$(aws ec2 describe-instances --query "Reservations[*].Instances[*].InstanceId[]" --filters "Name=vpc-id,Values=${vpc_id}" | jq '.[]' --raw-output)

  for i in $found_instances
  do
    instance_tags=$(aws ec2 describe-instances --instance-ids $i | jq '.Reservations[].Instances[].Tags[].Value')
    if ! [[ ${instance_tags} =~ "${stack_name}" ]] ; then
      echo "Error: Unexpected instances found on ${vpc_id}: ${i}"
      exit 1
    fi
  done
fi
