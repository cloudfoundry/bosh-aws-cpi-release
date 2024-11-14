#!/usr/bin/env bash

set -eu

fly -t bosh sp -p bosh-aws-cpi \
  -c ci/pipeline.yml

