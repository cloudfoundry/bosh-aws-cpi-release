#!/usr/bin/env bash

set -e

: ${BOSH_AWS_KMS_KEY_ARN:?}

source bosh-cpi-src/ci/utils.sh
source director-state/director.env

# CREATE TEST RELEASE
pushd bosh-cpi-src/ci/assets/e2e-test-release
  time bosh -n create-release --force --name e2e-test --version 1.0.0
  time bosh -n upload-release
popd

# UPLOAD STEMCELL
time bosh -n upload-stemcell "$(realpath stemcell/*.tgz)"
time bosh -n upload-stemcell "$(realpath heavy-stemcell/*.tgz)"

stemcell_name="$( bosh int <( tar xfO $(realpath stemcell/*.tgz) stemcell.MF ) --path /name )"
heavy_stemcell_name="$( bosh int <( tar xfO $(realpath heavy-stemcell/*.tgz) stemcell.MF ) --path /name )"

time bosh repack-stemcell \
  --name e2e-encrypted-heavy-stemcell \
  --version 0.1 \
  --cloud-properties "{\"encrypted\": true, \"kms_key_arn\": \"${BOSH_AWS_KMS_KEY_ARN}\"}" \
  "$(realpath heavy-stemcell/*.tgz)" \
  /tmp/e2e-encrypted-heavy-stemcell.tgz
time bosh -n upload-stemcell /tmp/e2e-encrypted-heavy-stemcell.tgz
encrypted_heavy_stemcell_ami_id="$( bosh stemcells | grep e2e-encrypted-heavy-stemcell | awk '{print $NF;}' )"

# UPDATE CLOUD CONFIG
time bosh -n ucc \
  -l environment/metadata \
  bosh-cpi-src/ci/assets/e2e-test-release/cloud-config.yml

# BOSH DEPLOY
time bosh -n deploy -d e2e-test \
  -v "stemcell_name=${stemcell_name}" \
  -v "heavy_stemcell_name=${heavy_stemcell_name}" \
  -v "encrypted_heavy_stemcell_ami_id=${encrypted_heavy_stemcell_ami_id}" \
  -v "aws_kms_key_arn=${BOSH_AWS_KMS_KEY_ARN}" \
  -l environment/metadata \
  bosh-cpi-src/ci/assets/e2e-test-release/manifest.yml

# RUN ERRANDS
time bosh -n run-errand -d e2e-test iam-instance-profile-test
time bosh -n run-errand -d e2e-test raw-ephemeral-disk-test
time bosh -n run-errand -d e2e-test elb-registration-test
time bosh -n run-errand -d e2e-test heavy-stemcell-test
time bosh -n run-errand -d e2e-test encrypted-heavy-stemcell-test

# spot instances do not work in China
region=$( jq -e --raw-output ".region" environment/metadata )
if [[ "${region}" != "cn-north-1" ]]; then
  time bosh -n run-errand -d e2e-test spot-instance-test
else
  echo "Skipping spot instance tests for ${region}..."
fi
