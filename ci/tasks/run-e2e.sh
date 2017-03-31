#!/usr/bin/env bash

set -e

: ${AWS_ACCESS_KEY:?}
: ${AWS_SECRET_KEY:?}
: ${AWS_REGION_NAME:?}
: ${BOSH_CLIENT:?}
: ${BOSH_CLIENT_SECRET:?}
: ${STEMCELL_NAME:?}
: ${HEAVY_STEMCELL_NAME:?}
: ${METADATA_FILE:=environment/metadata}
: ${AWS_KMS_KEY_ARN:?}

export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY}
export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_KEY}
export AWS_DEFAULT_REGION=${AWS_REGION_NAME}

# inputs
stemcell_path="$(realpath stemcell/*.tgz)"
heavy_stemcell_path="$(realpath heavy-stemcell/*.tgz)"
e2e_release="$(realpath pipelines/aws/assets/e2e-test-release)"
bosh_cli=$(realpath bosh-cli/bosh-cli-*)
chmod +x $bosh_cli

export SUBNET_ID=$(jq -e --raw-output ".PublicSubnetID" "${METADATA_FILE}")
export AVAILABILITY_ZONE=$(jq -e --raw-output ".AvailabilityZone" "${METADATA_FILE}")
export DIRECTOR_IP=$(jq -e --raw-output ".DirectorEIP" "${METADATA_FILE}")
export IAM_INSTANCE_PROFILE=$(jq -e --raw-output ".IAMInstanceProfile" "${METADATA_FILE}")
export ELB_NAME=$(jq -e --raw-output ".ELB_e2e" "${METADATA_FILE}")
export BOSH_ENVIRONMENT="${DIRECTOR_IP//./-}.sslip.io"

e2e_deployment_name=e2e-test
e2e_release_version=1.0.0

# TODO: remove `cp` line once this story has been accepted: https://www.pivotaltracker.com/story/show/128789021
e2e_release_home="$HOME/${e2e_release##*/}"
cp -r ${e2e_release} ${e2e_release_home}
pushd ${e2e_release_home}
  time $bosh_cli -n create-release --force --name ${e2e_deployment_name} --version ${e2e_release_version}
  time $bosh_cli -n upload-release
popd

time $bosh_cli -n upload-stemcell "${stemcell_path}"
time $bosh_cli -n upload-stemcell "${heavy_stemcell_path}"

time $bosh_cli repack-stemcell \
  --name e2e-encrypted-heavy-stemcell \
  --version 0.1 \
  --cloud-properties "{\"encrypted\": true, \"kms_key_arn\": \"${AWS_KMS_KEY_ARN}\"}" \
  "${heavy_stemcell_path}" \
  /tmp/e2e-encrypted-heavy-stemcell.tgz
time $bosh_cli -n upload-stemcell /tmp/e2e-encrypted-heavy-stemcell.tgz
ami_id="$( $bosh_cli stemcells | grep e2e-encrypted-heavy-stemcell | awk '{print $NF;}' )"

e2e_manifest_filename=e2e-manifest.yml
e2e_cloud_config_filename=e2e-cloud-config.yml

# these VM's are expected to have `director` role for them to succeed
cat > "${e2e_cloud_config_filename}" <<EOF
networks:
  - name: private
    type: dynamic
    cloud_properties: {subnet: ${SUBNET_ID}}

vm_types:
  - name: default
    cloud_properties: &default_cloud_properties
      instance_type: t2.medium
      availability_zone: ${AVAILABILITY_ZONE}
  - name: iam_role
    cloud_properties:
      <<: *default_cloud_properties
      iam_instance_profile: ${IAM_INSTANCE_PROFILE}
  - name: raw_ephemeral_pool
    cloud_properties:
      instance_type: m3.medium
      availability_zone: ${AVAILABILITY_ZONE}
      raw_instance_storage: true
  - name: elb_registration_pool
    cloud_properties:
      <<: *default_cloud_properties
      elbs: [${ELB_NAME}]
  - name: spot_instance_pool
    cloud_properties:
      <<: *default_cloud_properties
      spot_bid_price: 0.10 # 10x the normal bid price

compilation:
  reuse_compilation_vms: true
  workers: 1
  network: private
  cloud_properties:
    instance_type: t2.medium
    availability_zone: ${AVAILABILITY_ZONE}
EOF


cat > "${e2e_manifest_filename}" <<EOF
---
name: ${e2e_deployment_name}

releases:
  - name: ${e2e_deployment_name}
    version: latest

update:
  canaries: 1
  canary_watch_time: 30000-240000
  update_watch_time: 30000-600000
  max_in_flight: 3

stemcells:
  - alias: stemcell
    name: ${STEMCELL_NAME}
    version: latest
  - alias: heavy-stemcell
    name: ${HEAVY_STEMCELL_NAME}
    version: latest

instance_groups:
  - name: iam-instance-profile-test
    jobs:
    - name: iam-instance-profile-test
      release: ${e2e_deployment_name}
      properties:
        expected_iam_instance_profile: ${IAM_INSTANCE_PROFILE}
    stemcell: stemcell
    lifecycle: errand
    instances: 1
    vm_type: iam_role
    networks:
      - name: private
        default: [dns, gateway]
  - name: raw-ephemeral-disk-test
    jobs:
      - name: raw-ephemeral-disk-test
        release: ${e2e_deployment_name}
        properties: {}
    stemcell: stemcell
    lifecycle: errand
    instances: 1
    vm_type: raw_ephemeral_pool
    networks:
      - name: private
        default: [dns, gateway]
  - name: elb-registration-test
    jobs:
      - name: elb-registration-test
        release: ${e2e_deployment_name}
        properties:
          load_balancer_name: ${ELB_NAME}
          aws_region: ${AWS_REGION_NAME}
    stemcell: stemcell
    lifecycle: errand
    instances: 1
    vm_type: elb_registration_pool
    networks:
      - name: private
        default: [dns, gateway]
  - name: spot-instance-test
    jobs:
      - name: spot-instance-test
        release: ${e2e_deployment_name}
        properties:
          aws_region: ${AWS_REGION_NAME}
    stemcell: stemcell
    lifecycle: errand
    instances: 1
    vm_type: spot_instance_pool
    networks:
      - name: private
        default: [dns, gateway]
  - name: heavy-stemcell-test
    jobs:
      - name: heavy-stemcell-test
        release: ${e2e_deployment_name}
        properties: {}
    stemcell: heavy-stemcell
    lifecycle: errand
    instances: 1
    vm_type: default
    networks:
      - name: private
        default: [dns, gateway]
  - name: encrypted-heavy-stemcell-test
    jobs:
      - name: encrypted-heavy-stemcell-test
        release: ${e2e_deployment_name}
        properties:
          aws_region: ${AWS_REGION_NAME}
          aws_kms_key_arn: ${AWS_KMS_KEY_ARN}
          aws_ami_cid: ${ami_id}
    stemcell: heavy-stemcell
    lifecycle: errand
    instances: 1
    vm_type: default
    networks:
      - name: private
        default: [dns, gateway]
EOF

time $bosh_cli -n update-cloud-config "${e2e_cloud_config_filename}"

time $bosh_cli -n deploy -d ${e2e_deployment_name} "${e2e_manifest_filename}"

time $bosh_cli -n run-errand -d ${e2e_deployment_name} iam-instance-profile-test

time $bosh_cli -n run-errand -d ${e2e_deployment_name} raw-ephemeral-disk-test

time $bosh_cli -n run-errand -d ${e2e_deployment_name} elb-registration-test

time $bosh_cli -n run-errand -d ${e2e_deployment_name} heavy-stemcell-test

time $bosh_cli -n run-errand -d ${e2e_deployment_name} encrypted-heavy-stemcell-test

# spot instances do not work in China
if [ "${AWS_REGION_NAME}" != "cn-north-1" ]; then
  time $bosh_cli -n run-errand -d ${e2e_deployment_name} spot-instance-test
else
  echo "Skipping spot instance tests for ${AWS_REGION_NAME}..."
fi
