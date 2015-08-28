#!/usr/bin/env bash

set -e -x

source bosh-cpi-release/ci/tasks/utils.sh

check_param aws_access_key_id
check_param aws_secret_access_key
check_param region_name

export AWS_ACCESS_KEY_ID=${aws_access_key_id}
export AWS_SECRET_ACCESS_KEY=${aws_secret_access_key}
export AWS_DEFAULT_REGION=${region_name}

stack_name="aws-cpi-stack"

aws cloudformation delete-stack --stack-name ${stack_name}

describe_cmd="aws cloudformation describe-stacks --stack-name ${stack_name}"

while true; do
  if stack_info=$(${describe_cmd}); then
    stack_status=$(echo $stack_info | jq '.Stacks[].StackStatus')
    if [ $stack_status != '"DELETE_IN_PROGRESS"' ]; then
      echo "Expecting the stack to either be deleted or in the process of being deleted but was ${stack_status}"
      echo ${stack_info}
      exit 1
    fi
    echo "sleeping 5"
    sleep 5s
  else
    break
  fi
done

aws cloudformation create-stack \
    --stack-name      ${stack_name} \
    --template-body   file:///${PWD}/bosh-cpi-release/ci/assets/cloudformation.template

stack_info=$(aws cloudformation describe-stacks --stack-name ${stack_name})
stack_status=$(echo $stack_info | jq '.Stacks[].StackStatus')
while true; do
  echo "StackStatus ${stack_status}"
  if [ $stack_status == '"CREATE_IN_PROGRESS"' ]; then
  echo "sleeping 5"
  sleep 5s
  stack_info=$(aws cloudformation describe-stacks --stack-name ${stack_name})
  stack_status=$(echo $stack_info | jq '.Stacks[].StackStatus')
done

if [ $stack_status != '"CREATE_COMPLETE"' ]; then
  echo "cloudformation failed stack info:\n${stack_info}"
  exit 1
fi
