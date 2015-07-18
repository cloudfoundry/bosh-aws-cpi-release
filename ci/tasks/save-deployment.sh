#!/usr/bin/env bash

set -e -x

source bosh-cpi-release/ci/tasks/utils.sh

check_param base_os

manifest_dir=bosh-concourse-ci/pipelines/bosh-aws-cpi

echo "checking in BOSH deployment state"
cd deploy/${manifest_dir}
git add ${base_os}-director-manifest-state.json
git config --global user.email "cf-bosh-eng+bosh-ci@pivotal.io"
git config --global user.name "bosh-ci"
git commit -m ":airplane: Concourse auto-updating deployment state for bats pipeline, on ${base_os}"
