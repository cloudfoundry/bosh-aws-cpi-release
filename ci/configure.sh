#!/usr/bin/env bash

set -eu

fly -t bosh-ecosystem sp -p bosh-aws-cpi \
  -c ci/pipeline.yml \
  -l <( lpass show --notes "aws cpi concourse secrets") \
  -l <( lpass show --notes pivotal-tracker-resource-keys ) \
  -l <( lpass show --note "bosh:docker-images concourse secrets") \

