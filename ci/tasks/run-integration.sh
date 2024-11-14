#!/usr/bin/env bash

set -e

: ${AWS_ACCESS_KEY_ID:?}
: ${AWS_SECRET_ACCESS_KEY:?}
: ${AWS_DEFAULT_REGION:?}
: ${BOSH_AWS_KMS_KEY_ARN:?}
: ${BOSH_AWS_KMS_KEY_ARN_OVERRIDE:?}
: ${BOSH_AWS_WINDOWS_IMAGE_ID:?}

tar -xzf stemcell/stemcell.tgz stemcell.MF
export BOSH_AWS_IMAGE_ID=$(cat stemcell.MF | grep $AWS_DEFAULT_REGION | tr -d ' ' | cut -f2 -d:)

# NOTE: To run with specific line numbers, set:
# RSPEC_ARGUMENTS="spec/integration/lifecycle_spec.rb:mm:nn"
: ${RSPEC_ARGUMENTS:=spec/integration}
: ${METADATA_FILE:=environment/metadata}

release_dir="$( cd $(dirname $0) && cd ../.. && pwd )"

metadata=$(cat ${METADATA_FILE})

export BOSH_AWS_CPI_API_VERSION=${BOSH_AWS_CPI_API_VERSION}
export BOSH_AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
export BOSH_AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
if [ "${AWS_SESSION_TOKEN}" ]; then
	export BOSH_AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN}
fi

export BOSH_AWS_DEFAULT_KEY_NAME=$(echo ${metadata} | jq -e --raw-output ".default_key_name")
export BOSH_AWS_REGION=$(echo ${metadata} | jq -e --raw-output ".region")
export BOSH_AWS_SUBNET_ID=$(echo ${metadata} | jq -e --raw-output ".subnet_id")
export BOSH_AWS_MANUAL_SUBNET_ID=$(echo ${metadata} | jq -e --raw-output ".manual_subnet_id")
export BOSH_AWS_SUBNET_ZONE=$(echo ${metadata} | jq -e --raw-output ".az")
export BOSH_AWS_LIFECYCLE_MANUAL_IP=$(echo ${metadata} | jq -e --raw-output ".internal_ip")
export BOSH_AWS_ELB_ID=$(echo ${metadata} | jq -e --raw-output ".elb")
export BOSH_AWS_TARGET_GROUP_NAME=$(echo ${metadata} | jq -e --raw-output ".alb_target_group")
export BOSH_AWS_ELASTIC_IP=$(echo ${metadata} | jq -e --raw-output ".bats_eip")
export BOSH_AWS_MANUAL_IPV6_IP=$(echo ${metadata} | jq -e --raw-output ".manual_static_ipv6")
export BOSH_AWS_ADVERTISED_ROUTE_TABLE=$(echo ${metadata} | jq -e --raw-output ".advertised_route_table")

export BOSH_CLI_SILENCE_SLOW_LOAD_WARNING=true

pushd ${release_dir}
  source .envrc

  pushd src/bosh_aws_cpi > /dev/null
    bundle install
    bundle exec rspec ${RSPEC_ARGUMENTS}
  popd > /dev/null
popd
