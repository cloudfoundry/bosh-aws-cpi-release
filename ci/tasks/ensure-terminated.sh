#!/usr/bin/env bash
set -eu -o pipefail

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION}"

set -x

# set this to empty string the cli doesn't fail looking for `less`
export AWS_PAGER=

vpc_id=$(jq --raw-output '.vpc_id' < environment/metadata)

if [[ -n "${vpc_id}" ]] ; then
  instance_list=$(
    aws ec2 describe-instances --query "Reservations[*].Instances[*].InstanceId[]" --filters "Name=vpc-id,Values=${vpc_id}" \
      | jq --raw-output '. | join(" ")'
  )

  # if it's not an empty string (of any length)...
  if [[ -n "${instance_list// }" ]] ; then
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --instance-ids ${instance_list}
  fi
fi
