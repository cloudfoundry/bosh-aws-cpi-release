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

echo "using bosh-init CLI version..."
$initexe version

echo "deleting existing BOSH Director VM..."
$initexe delete ${manifest_filename}
