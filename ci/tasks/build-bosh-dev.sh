#!/usr/bin/env bash

set -e

export version=$(cat bosh-dev-version/version)
export ROOT_PATH=$PWD

mv bosh-cli/*-linux-amd64 bosh-cli/bosh-cli
export GO_CLI_PATH=$ROOT_PATH/bosh-cli/bosh-cli
chmod +x $GO_CLI_PATH

cd bosh-src

sed -i "s/\['version'\] = ..*/['version'] = '$version'/" jobs/director/templates/director.yml.erb

$GO_CLI_PATH create-release --tarball=../release/bosh-dev-release-for-cpi-refactor.tgz --timestamp-version --force
