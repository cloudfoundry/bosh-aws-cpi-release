#!/usr/bin/env bash

set -e

source bosh-cpi-release/ci/tasks/utils.sh

check_param base_os

source /etc/profile.d/chruby.sh
chruby 2.1.2

#move director manifest to director state file directory
manifest_dir="${PWD}/director-state-file"
manifest_filename=${manifest_dir}/${base_os}-director-manifest.yml
cp ${PWD}/director-manifest-file/${base_os}-director-manifest.yml  ${manifest_filename}


#on success, clean up bosh director
initver=$(cat bosh-init/version)
initexe="$PWD/bosh-init/bosh-init-${initver}-linux-amd64"
chmod +x $initexe

echo "normalizing paths to match values referenced in $manifest_filename"
# manifest paths are now relative so the tmp inputs need to be updated
mkdir ${manifest_dir}/tmp
semver=$(cat version-semver/number)
cp ./bosh-cpi-dev-artifacts/bosh-aws-cpi-${semver}.tgz ${manifest_dir}/tmp/bosh-aws-cpi.tgz
cp ./bosh-release/release.tgz ${manifest_dir}/tmp/bosh-release.tgz
cp ./stemcell/stemcell.tgz ${manifest_dir}/tmp/stemcell.tgz
cp ./bosh-concourse-ci/pipelines/bosh-aws-cpi/bats.pem ${manifest_dir}/tmp/bats.pem

echo "using bosh-init CLI version..."
$initexe version

echo "deleting existing BOSH Director VM..."
$initexe delete ${manifest_filename}
