#!/usr/bin/env bash

set -e

export version=$(cat bosh-dev-version/version)
export ROOT_PATH=$PWD

cd bosh-src

sed -i "s/\['version'\] = ..*/['version'] = '$version'/" jobs/director/templates/director.yml.erb

bosh create-release --tarball=../release/bosh-dev-release-for-cpi-refactor.tgz --timestamp-version --force
