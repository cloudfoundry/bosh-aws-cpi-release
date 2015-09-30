#!/usr/bin/env bash

set -e

source bosh-cpi-release/ci/tasks/utils.sh

check_param aws_access_key_id
check_param aws_secret_access_key
check_param region_name

export AWS_ACCESS_KEY_ID=${aws_access_key_id}
export AWS_SECRET_ACCESS_KEY=${aws_secret_access_key}
export AWS_DEFAULT_REGION=${region_name}

stack_name="aws-cpi-stack"

stack_info=$(get_stack_info $stack_name)
vpc_id=$(get_stack_info_of "$stack_info" "VPCID")
instances=$(aws ec2 describe-instances --query "Reservations[*].Instances[*].InstanceId[]" --filters "Name=vpc-id,Values=${vpc_id}")

if [ ! -z "$instances" ] ; then
  echo "Error: Alive instances found on ${vpc_id}: ${instances}"
  exit 1
fi

cmd="aws cloudformation delete-stack --stack-name ${stack_name}"
echo "Running: ${cmd}"; ${cmd}

while true; do
  stack_status=$(get_stack_status $stack_name)
  echo "StackStatus ${stack_status}"
  if [[ -z "$stack_status" ]]; then #get empty status due to stack not existed on aws
    echo "No stack found"; break
    break
  elif [ $stack_status == 'DELETE_IN_PROGRESS' ]; then
    echo "${stack_status}: sleeping 5s"; sleep 5s
  else
    echo "Expecting the stack to either be deleted or in the process of being deleted but was ${stack_status}"
    echo $(get_stack_info $stack_name)
    exit 1
  fi
done

cmd="aws cloudformation create-stack \
    --stack-name      ${stack_name} \
    --template-body   file:///${PWD}/bosh-cpi-release/ci/assets/cloudformation.template.json \
    --capabilities    CAPABILITY_IAM"

echo "Running: ${cmd}"; ${cmd}
while true; do
  stack_status=$(get_stack_status $stack_name)
  echo "StackStatus ${stack_status}"
  if [ $stack_status == 'CREATE_IN_PROGRESS' ]; then
    echo "sleeping 5s"; sleep 5s
  else
    break
  fi
done

if [ $stack_status != 'CREATE_COMPLETE' ]; then
  echo "cloudformation failed stack info:\n$(get_stack_info $stack_name)"
  exit 1
fi
