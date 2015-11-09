#!/usr/bin/env bash

set -e

source bosh-cpi-release/ci/tasks/utils.sh

out_dir="${PWD}/china-light-stemcell"

light_stemcell_name=light-china-bosh-stemcell-9999-aws-xen-ubuntu-trusty-go_agent.tgz

mkdir -p workspace

pushd workspace
  echo "testing" > testing.txt
  tar -czvf ${light_stemcell_name} testing.txt
popd

mkdir -p ${out_dir}
mv workspace/${light_stemcell_name} ${out_dir}
