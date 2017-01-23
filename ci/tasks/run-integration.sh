#!/usr/bin/env bash

set -e

: ${AWS_ACCESS_KEY_ID:?}
: ${AWS_SECRET_ACCESS_KEY:?}
: ${AWS_DEFAULT_REGION:?}
: ${AWS_PUBLIC_KEY_NAME:?}
: ${AWS_KMS_KEY_ARN:?}
: ${TERRAFORM_PATH:?}

# NOTE: To run with specific line numbers, set:
# RSPEC_ARGUMENTS="spec/integration/lifecycle_spec.rb:mm:nn"
: ${RSPEC_ARGUMENTS:=spec/integration}
: ${METADATA_FILE:=${TERRAFORM_PATH}/metadata}

release_dir="$( cd $(dirname $0) && cd ../.. && pwd )"

if [ -f "/etc/profile.d/chruby.sh" ] ; then
  source /etc/profile.d/chruby.sh
  chruby 2.1.2
fi

metadata=$(cat ${METADATA_FILE})

export BOSH_AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
export BOSH_AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
export BOSH_AWS_DEFAULT_KEY_NAME=${AWS_PUBLIC_KEY_NAME}
export BOSH_AWS_KMS_KEY_ARN=${AWS_KMS_KEY_ARN}
export BOSH_AWS_REGION=$(echo ${metadata} | jq -e --raw-output ".Region")
export BOSH_AWS_SUBNET_ID=$(echo ${metadata} | jq -e --raw-output ".PublicSubnetID")
export BOSH_AWS_SUBNET_ZONE=$(echo ${metadata} | jq -e --raw-output ".AvailabilityZone")
export BOSH_AWS_LIFECYCLE_MANUAL_IP=$(echo ${metadata} | jq -e --raw-output ".DirectorStaticIP")
export BOSH_AWS_ELB_ID=$(echo ${metadata} | jq -e --raw-output ".ELB")
export BOSH_AWS_TARGET_GROUP_NAME=$(echo ${metadata} | jq -e --raw-output ".ALBTargetGroup")

export BOSH_CLI_SILENCE_SLOW_LOAD_WARNING=true

pushd ${release_dir}/src/bosh_aws_cpi > /dev/null
  bundle install
  bundle exec rspec ${RSPEC_ARGUMENTS}
popd > /dev/null
