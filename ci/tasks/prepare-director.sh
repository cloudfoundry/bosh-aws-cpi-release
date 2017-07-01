#!/usr/bin/env bash

set -e

# inputs
release_dir="$( cd $(dirname $0) && cd ../.. && pwd )"
workspace_dir="$( cd ${release_dir} && cd .. && pwd )"
ci_environment_dir="${workspace_dir}/environment"
bosh_deployment="${workspace_dir}/bosh-deployment"
certification="${workspace_dir}/certification"
bosh_cli="${workspace_dir}/bosh-cli/*bosh-cli-*"
chmod +x $bosh_cli

# outputs
ci_output_dir="${workspace_dir}/director-config"

# environment
: ${AWS_ACCESS_KEY:?}
: ${AWS_SECRET_KEY:?}
: ${AWS_REGION_NAME:?}
: ${BOSH_CLIENT_SECRET:?}
: ${ENABLE_IAM_INSTANCE_PROFILE:=""}
: ${PUBLIC_KEY_NAME:?}
: ${PRIVATE_KEY_DATA:?}
: ${METADATA_FILE:=${ci_environment_dir}/metadata}
: ${OUTPUT_DIR:=${ci_output_dir}}

if [ ! -d ${OUTPUT_DIR} ]; then
  echo -e "OUTPUT_DIR '${OUTPUT_DIR}' does not exist"
  exit 1
fi
if [ ! -f ${METADATA_FILE} ]; then
  echo -e "METADATA_FILE '${METADATA_FILE}' does not exist"
  exit 1
fi

metadata="$( cat ${METADATA_FILE} )"
tmpdir="$(mktemp -d /tmp/bosh-director-artifacts.XXXXXXXXXX)"

BOSH_RELEASE_URI="file://$( echo bosh-release/*.tgz )"
CPI_RELEASE_URI="file://$( echo cpi-release/*.tgz )"
STEMCELL_URI="file://$( echo stemcell/*.tgz )"

# configuration
: ${SECURITY_GROUP:=$(       echo ${metadata} | jq --raw-output ".security_group_name" )}
: ${DIRECTOR_EIP:=$(         echo ${metadata} | jq --raw-output ".director_eip" )}
: ${SUBNET_ID:=$(            echo ${metadata} | jq --raw-output ".subnet_id" )}
: ${AVAILABILITY_ZONE:=$(    echo ${metadata} | jq --raw-output ".availability_zone" )}
: ${AWS_NETWORK_CIDR:=$(     echo ${metadata} | jq --raw-output ".network_cidr" )}
: ${AWS_NETWORK_GATEWAY:=$(  echo ${metadata} | jq --raw-output ".network_gateway" )}
: ${AWS_NETWORK_DNS:=$(      echo ${metadata} | jq --raw-output ".dns" )}
: ${DIRECTOR_STATIC_IP:=$(   echo ${metadata} | jq --raw-output ".director_internal_ip" )}
: ${STATIC_RANGE:=$(         echo ${metadata} | jq --raw-output ".network_static_range" )}
: ${RESERVED_RANGE:=$(       echo ${metadata} | jq --raw-output ".network_reserved_range" )}

iam_instance_profile_ops=""
if [ "${ENABLE_IAM_INSTANCE_PROFILE}" == true ]; then
  iam_instance_profile_ops="--ops-file /tmp/iam-instance-profile-ops.yml"

  : ${IAM_INSTANCE_PROFILE:=$( echo ${metadata} | jq --raw-output ".iam_instance_profile" )}
  cat > /tmp/iam-instance-profile-ops.yml <<EOF
---
- type: replace
  path: /resource_pools/name=vms/cloud_properties/iam_instance_profile?
  value: ((iam_instance_profile))

- type: replace
  path: /instance_groups/name=bosh/properties/aws/default_iam_instance_profile?
  value: ((iam_instance_profile))
EOF
fi

# keys
shared_key="shared.pem"
echo "${PRIVATE_KEY_DATA}" > "${OUTPUT_DIR}/${shared_key}"

# env file generation
cat > "${OUTPUT_DIR}/director.env" <<EOF
#!/usr/bin/env bash

export BOSH_ENVIRONMENT=${DIRECTOR_EIP}
export BOSH_CLIENT=admin
export BOSH_CLIENT_SECRET=${BOSH_CLIENT_SECRET}
EOF

cat > /tmp/aws_creds.yml <<EOF
---
iam_instance_profile: ${IAM_INSTANCE_PROFILE}
private_key: ${shared_key}
access_key_id: ${AWS_ACCESS_KEY}
secret_access_key: ${AWS_SECRET_KEY}
default_key_name: ${PUBLIC_KEY_NAME}
default_security_groups: [${SECURITY_GROUP}]
region: ${AWS_REGION_NAME}
az: ${AVAILABILITY_ZONE}
external_ip: ${DIRECTOR_EIP}
internal_gw: ${AWS_NETWORK_GATEWAY}
internal_ip: ${DIRECTOR_STATIC_IP}
internal_cidr: ${AWS_NETWORK_CIDR}
subnet_id: ${SUBNET_ID}
admin_password: ${BOSH_CLIENT_SECRET}
dns_recursor_ip: 10.0.0.2
EOF

cat > "${OUTPUT_DIR}/cloud-config.yml" <<EOF
azs:
- name: z1
  cloud_properties:
    availability_zone: ${AVAILABILITY_ZONE}

vm_types:
- name: default
  cloud_properties:
    instance_type: t2.micro
    ephemeral_disk: {size: 3000}

disk_types:
- name: default
  disk_size: 3000
  cloud_properties: {}

networks:
- name: default
  type: manual
  subnets:
  - range:    ${AWS_NETWORK_CIDR}
    gateway:  ${AWS_NETWORK_GATEWAY}
    az:       z1
    dns:      [8.8.8.8]
    static:   [${STATIC_RANGE}]
    reserved:   [${RESERVED_RANGE}]
    cloud_properties:
      subnet: ${SUBNET_ID}
- name: vip
  type: vip

compilation:
  workers: 5
  reuse_compilation_vms: true
  az: z1
  vm_type: default
  network: default
EOF

${bosh_cli} interpolate \
  --ops-file ${bosh_deployment}/aws/cpi.yml \
  --ops-file ${bosh_deployment}/powerdns.yml \
  --ops-file ${bosh_deployment}/external-ip-with-registry-not-recommended.yml \
  --ops-file ${certification}/shared/assets/ops/custom-releases.yml \
  --ops-file ${certification}/aws/assets/ops/custom-releases.yml \
  $(echo ${iam_instance_profile_ops}) \
  -v bosh_release_uri="${BOSH_RELEASE_URI}" \
  -v cpi_release_uri="${CPI_RELEASE_URI}" \
  -v stemcell_uri="${STEMCELL_URI}" \
  -l /tmp/aws_creds.yml \
  ${bosh_deployment}/bosh.yml > "${OUTPUT_DIR}/director.yml"


echo -e "Successfully generated manifest!"
echo -e "Manifest:    ${OUTPUT_DIR}/director.yml"
echo -e "Env:         ${OUTPUT_DIR}/director.env"
echo -e "CloudConfig: ${OUTPUT_DIR}/cloud-config.yml"
echo -e "Artifacts:   ${tmpdir}/"
