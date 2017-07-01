#!/usr/bin/env bash

set -e

: ${STEMCELL_NAME:?}
: ${HEAVY_STEMCELL_NAME:?}
: ${AWS_KMS_KEY_ARN:?}

bosh_cli=$(realpath bosh-cli/bosh-cli-*)
chmod +x $bosh_cli
alias bosh2=$bosh_cli

source director-state/director.env

pushd pipelines/aws/assets/e2e-test-release
  time bosh2 -n create-release --force --name e2e-test --version 1.0.0
  time bosh2 -n upload-release
popd

time bosh2 -n upload-stemcell "$(realpath stemcell/*.tgz)"
time bosh2 -n upload-stemcell "$(realpath heavy-stemcell/*.tgz)"

time bosh2 repack-stemcell \
  --name e2e-encrypted-heavy-stemcell \
  --version 0.1 \
  --cloud-properties "{\"encrypted\": true, \"kms_key_arn\": \"${AWS_KMS_KEY_ARN}\"}" \
  "$(realpath heavy-stemcell/*.tgz)" \
  /tmp/e2e-encrypted-heavy-stemcell.tgz
time bosh2 -n upload-stemcell /tmp/e2e-encrypted-heavy-stemcell.tgz
encrypted_heavy_stemcell_ami_id="$( bosh2 stemcells | grep e2e-encrypted-heavy-stemcell | awk '{print $NF;}' )"

time bosh2 -n ucc \
  -l environment/metadata \
  pipelines/aws/assets/e2e-test-release/cloud-config-2.yml

time bosh2 -n deploy -d e2e-test \
  -v "aws_kms_key_arn=${AWS_KMS_KEY_ARN}" \
  -v "encrypted_heavy_stemcell_ami_id=${encrypted_heavy_stemcell_ami_id}" \
  -l environment/metadata \
  pipelines/aws/assets/e2e-test-release/manifest.yml

time bosh2 -n run-errand -d e2e-test iam-instance-profile-test
time bosh2 -n run-errand -d e2e-test raw-ephemeral-disk-test
time bosh2 -n run-errand -d e2e-test elb-registration-test
time bosh2 -n run-errand -d e2e-test heavy-stemcell-test
time bosh2 -n run-errand -d e2e-test encrypted-heavy-stemcell-test

# spot instances do not work in China
region=$( jq -e --raw-output ".region" environment/metadata )
if [ "${region}" != "cn-north-1" ]; then
  time bosh2 -n run-errand -d e2e-test spot-instance-test
else
  echo "Skipping spot instance tests for ${region}..."
fi
