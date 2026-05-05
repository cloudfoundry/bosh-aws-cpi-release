#!/usr/bin/env bash

set -e

: ${BOSH_AWS_KMS_KEY_ARN:?}
export AWS_PAGER=

source director-state/director.env

# CREATE TEST RELEASE
pushd bosh-aws-cpi-release/ci/assets/e2e-test-release
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
  bosh-aws-cpi-release/ci/assets/e2e-test-release/cloud-config.yml

# BOSH DEPLOY
time bosh -n deploy -d e2e-test \
  -v "stemcell_name=${stemcell_name}" \
  -v "heavy_stemcell_name=${heavy_stemcell_name}" \
  -v "encrypted_heavy_stemcell_ami_id=${encrypted_heavy_stemcell_ami_id}" \
  -v "aws_kms_key_arn=${BOSH_AWS_KMS_KEY_ARN}" \
  -l environment/metadata \
  bosh-aws-cpi-release/ci/assets/e2e-test-release/manifest.yml

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

# test tags applied on create
account_id=$( aws sts get-caller-identity --query Account --output text )
policy_arn="arn:aws:iam::${account_id}:policy/EnforceRequiredTags"

cleanup_enforce_tags_policy() {
  local attached

  attached=$(aws iam list-entities-for-policy \
    --policy-arn "${policy_arn}" \
    --query 'PolicyUsers[].UserName' \
    --output text 2>/dev/null) || true
  for user_name in ${attached}; do
    [[ "${user_name}" == "None" ]] && continue
    aws iam detach-user-policy \
      --user-name "${user_name}" \
      --policy-arn "${policy_arn}" || true
  done

  attached=$(aws iam list-entities-for-policy \
    --policy-arn "${policy_arn}" \
    --query 'PolicyRoles[].RoleName' \
    --output text 2>/dev/null) || true
  for role_name in ${attached}; do
    [[ "${role_name}" == "None" ]] && continue
    aws iam detach-role-policy \
      --role-name "${role_name}" \
      --policy-arn "${policy_arn}" || true
  done

  attached=$(aws iam list-entities-for-policy \
    --policy-arn "${policy_arn}" \
    --query 'PolicyGroups[].GroupName' \
    --output text 2>/dev/null) || true
  for group_name in ${attached}; do
    [[ "${group_name}" == "None" ]] && continue
    aws iam detach-group-policy \
      --group-name "${group_name}" \
      --policy-arn "${policy_arn}" || true
  done

  aws iam delete-policy \
    --policy-arn "${policy_arn}" || true
}

# Register cleanup before creating the policy so that any exit (including
# SIGTERM from a Concourse abort) leaves no policy behind from a prior run.
trap cleanup_enforce_tags_policy EXIT

# Detach from all entities and delete any leftover policy from a previous failed run.
cleanup_enforce_tags_policy

aws iam create-policy \
  --policy-name EnforceRequiredTags \
  --policy-document file://bosh-aws-cpi-release/ci/assets/e2e-test-release/enforce-tags-policy.json \
  --description "Requires BoshCPITest tag on resource creation"

echo "--- Attaching Deny policy to IAM user: ${IAM_USER} ---"
aws iam attach-user-policy \
  --user-name "${IAM_USER}" \
  --policy-arn "${policy_arn}"

echo "--- Waiting for IAM policy to propagate ---"
sleep 30


echo "--- Testing resource creation ---"
time bosh -n run-errand -d e2e-test regular-vm-disk-test

if [[ "${region}" != "cn-north-1" ]]; then
   time bosh -n run-errand -d e2e-test spot-instance-test
else
  echo "Skipping spot instance tests for ${region}..."
fi

trap - EXIT
cleanup_enforce_tags_policy