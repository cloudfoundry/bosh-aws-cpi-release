#!/usr/bin/env bash

set -e

: ${AWS_ACCESS_KEY_ID:?}
: ${AWS_SECRET_ACCESS_KEY:?}
: ${AWS_DEFAULT_REGION:?}
: ${AWS_PUBLIC_KEY_NAME:?}

# NOTE: To run with specific line numbers, set:
# RSPEC_ARGUMENTS="spec/integration/lifecycle_spec.rb:mm:nn"
: ${RSPEC_ARGUMENTS:=spec/integration}
: ${METADATA_FILE:=environment/metadata}

release_dir="$( cd $(dirname $0) && cd ../.. && pwd )"

if [ -f "/etc/profile.d/chruby.sh" ] ; then
  source /etc/profile.d/chruby.sh
  chruby 2.1.2
fi

metadata=$(cat ${METADATA_FILE})

export BOSH_AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
export BOSH_AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
export BOSH_AWS_DEFAULT_KEY_NAME=${AWS_PUBLIC_KEY_NAME}
export BOSH_AWS_SUBNET_ID=$(echo ${metadata} | jq --raw-output ".PublicSubnetID")
export BOSH_AWS_SUBNET_ZONE=$(echo ${metadata} | jq --raw-output ".AvailabilityZone")
export BOSH_AWS_LIFECYCLE_MANUAL_IP=$(echo ${metadata} | jq --raw-output ".DirectorStaticIP")
export BOSH_AWS_ELB_ENDPOINT=$(echo ${metadata} | jq --raw-output ".ELBEndpoint")
export BOSH_AWS_ELB_ID=$(echo ${metadata} | jq --raw-output ".ELB")

export BOSH_CLI_SILENCE_SLOW_LOAD_WARNING=true

pushd ${release_dir}/src/bosh_aws_cpi > /dev/null
  bundle install
  bundle exec rspec ${RSPEC_ARGUMENTS}
popd > /dev/null
