#!/usr/bin/env bash

set -e

source bosh-cpi-src/ci/tasks/utils.sh

check_param stack_prefix
check_param stack_name
check_param aws_access_key_id
check_param aws_secret_access_key
check_param region_name
check_param private_key_data
check_param public_key_name
check_param director_username
check_param director_password
check_param use_iam

source /etc/profile.d/chruby.sh
chruby 2.1.2

export AWS_ACCESS_KEY_ID=${aws_access_key_id}
export AWS_SECRET_ACCESS_KEY=${aws_secret_access_key}
export AWS_DEFAULT_REGION=${region_name}

stack_info=$(get_stack_info $stack_name)

sg_id=$(get_stack_info_of "${stack_info}" "${stack_prefix}SecurityGroupID")
SECURITY_GROUP_NAME=$(aws ec2 describe-security-groups --group-ids ${sg_id} | jq -r '.SecurityGroups[] .GroupName')

DIRECTOR=$(get_stack_info_of "${stack_info}" "${stack_prefix}DirectorEIP")
SUBNET_ID=$(get_stack_info_of "${stack_info}" "${stack_prefix}SubnetID")
AVAILABILITY_ZONE=$(get_stack_info_of "${stack_info}" "${stack_prefix}AvailabilityZone")
AWS_NETWORK_CIDR=$(get_stack_info_of "${stack_info}" "${stack_prefix}CIDR")
AWS_NETWORK_GATEWAY=$(get_stack_info_of "${stack_info}" "${stack_prefix}Gateway")
PRIVATE_DIRECTOR_STATIC_IP=$(get_stack_info_of "${stack_info}" "${stack_prefix}DirectorStaticIP")

if [ -n "${use_iam}" ]; then
  IAM_INSTANCE_PROFILE=$(get_stack_info_of "${stack_info}" "${stack_prefix}IAMInstanceProfile")
  resource_pool_cloud_config_key="iam_instance_profile: ${IAM_INSTANCE_PROFILE}"
  read -r -d '' AWS_CONFIGURATION <<EO_AWS_CFG_IAM || true
    aws:
      credentials_source: 'env_or_profile'
      default_iam_instance_profile: ${IAM_INSTANCE_PROFILE}
      default_key_name: ${public_key_name}
      default_security_groups: ["${SECURITY_GROUP_NAME}"]
      region: "${region_name}"
EO_AWS_CFG_IAM
else
  read -r -d '' AWS_CONFIGURATION <<EO_AWS_CFG_STATIC || true
    aws:
      access_key_id: ${aws_access_key_id}
      secret_access_key: ${aws_secret_access_key}
      default_key_name: ${public_key_name}
      default_security_groups: ["${SECURITY_GROUP_NAME}"]
      region: "${region_name}"
EO_AWS_CFG_STATIC
fi

if [ -n "${blobstore_s3_region}" ]; then
  BLOBSTORE_BUCKET_NAME=$(get_stack_info_of "${stack_info}" "${stack_prefix}BlobstoreBucketName")
  read -r -d '' BLOBSTORE_CONFIGURATION <<EO_BLOBSTORE_CFG_S3 || true
    blobstore:
      provider: s3
      region: ${blobstore_s3_region}
      bucket_name: ${BLOBSTORE_BUCKET_NAME}
      access_key_id: ${aws_access_key_id}
      secret_access_key: ${aws_secret_access_key}
      director: {user: director, password: director-password}
      agent: {user: agent, password: agent-password}
EO_BLOBSTORE_CFG_S3
else
  read -r -d '' BLOBSTORE_CONFIGURATION <<EO_BLOBSTORE_CFG_DAV || true
    blobstore:
      provider: dav
      port: 25250
      address: ${PRIVATE_DIRECTOR_STATIC_IP}
      director: {user: director, password: director-password}
      agent: {user: agent, password: agent-password}
EO_BLOBSTORE_CFG_DAV
fi

cpi_release_name=bosh-aws-cpi
deployment_dir="${PWD}/deployment"
manifest_filename="director-manifest.yml"
private_key=${deployment_dir}/private_key.pem

echo "setting up artifacts used in $manifest_filename"
cp ./bosh-cpi-release/*.tgz ${deployment_dir}/${cpi_release_name}.tgz
cp ./bosh-release/release.tgz ${deployment_dir}/bosh-release.tgz
cp ./stemcell/*.tgz ${deployment_dir}/stemcell.tgz
echo "${private_key_data}" > ${private_key}
chmod go-r ${private_key}
eval $(ssh-agent)
ssh-add ${private_key}

cat > "${deployment_dir}/${manifest_filename}"<<EOF
---
name: bosh

releases:
- name: bosh
  url: file://bosh-release.tgz
- name: ${cpi_release_name}
  url: file://${cpi_release_name}.tgz

networks:
- name: private
  type: manual
  subnets:
  - range:    ${AWS_NETWORK_CIDR}
    gateway:  ${AWS_NETWORK_GATEWAY}
    dns:      [8.8.8.8]
    cloud_properties: {subnet: ${SUBNET_ID}}
- name: public
  type: vip

resource_pools:
- name: default
  network: private
  stemcell:
    url: file://stemcell.tgz
  cloud_properties:
    ${resource_pool_cloud_config_key}
    instance_type: m3.medium
    availability_zone: ${AVAILABILITY_ZONE}
    ephemeral_disk:
      size: 25000
      type: gp2

disk_pools:
- name: default
  disk_size: 25_000
  cloud_properties: {type: gp2}

jobs:
- name: bosh
  templates:
  - {name: nats, release: bosh}
  - {name: redis, release: bosh}
  - {name: postgres, release: bosh}
  - {name: blobstore, release: bosh}
  - {name: director, release: bosh}
  - {name: health_monitor, release: bosh}
  - {name: powerdns, release: bosh}
  - {name: registry, release: bosh}
  - {name: aws_cpi, release: ${cpi_release_name}}

  instances: 1
  resource_pool: default
  persistent_disk_pool: default

  networks:
  - name: private
    static_ips: [${PRIVATE_DIRECTOR_STATIC_IP}]
    default: [dns, gateway]
  - name: public
    static_ips: [${DIRECTOR}]

  properties:
    nats:
      address: 127.0.0.1
      user: nats
      password: nats-password

    redis:
      listen_addresss: 127.0.0.1
      address: 127.0.0.1
      password: redis-password

    postgres: &db
      host: 127.0.0.1
      user: postgres
      password: postgres-password
      database: bosh
      adapter: postgres

    # Tells the Director/agents how to contact registry
    registry:
      address: ${PRIVATE_DIRECTOR_STATIC_IP}
      host: ${PRIVATE_DIRECTOR_STATIC_IP}
      db: *db
      http: {user: ${director_username}, password: ${director_password}, port: 25777}
      username: ${director_username}
      password: ${director_password}
      port: 25777

    ${BLOBSTORE_CONFIGURATION}

    director:
      address: 127.0.0.1
      name: micro
      db: *db
      cpi_job: aws_cpi
      user_management:
        provider: local
        local:
          users:
            - {name: ${director_username}, password: ${director_password}}

    hm:
      http: {user: hm, password: hm-password}
      director_account: {user: ${director_username}, password: ${director_password}}

    dns:
      address: 127.0.0.1
      db: *db

    ${AWS_CONFIGURATION}

    # Tells agents how to contact nats
    agent: {mbus: "nats://nats:nats-password@${PRIVATE_DIRECTOR_STATIC_IP}:4222"}

    ntp: &ntp
    - 0.north-america.pool.ntp.org
    - 1.north-america.pool.ntp.org

cloud_provider:
  template: {name: aws_cpi, release: bosh-aws-cpi}

  # Tells bosh-micro how to SSH into deployed VM
  ssh_tunnel:
    host: ${DIRECTOR}
    port: 22
    user: vcap
    private_key: ${private_key}

  # Tells bosh-micro how to contact remote agent
  mbus: https://mbus-user:mbus-password@${DIRECTOR}:6868

  properties:
    aws:
      access_key_id: ${aws_access_key_id}
      secret_access_key: ${aws_secret_access_key}
      default_key_name: ${public_key_name}
      default_security_groups: ["${SECURITY_GROUP_NAME}"]
      region: "${region_name}"

    # Tells CPI how agent should listen for requests
    agent: {mbus: "https://mbus-user:mbus-password@0.0.0.0:6868"}

    blobstore:
      provider: local
      path: /var/vcap/micro_bosh/data/cache

    ntp: *ntp
EOF

pushd ${deployment_dir}

  function finish {
    echo "Final state of director deployment:"
    echo "=========================================="
    cat director-manifest-state.json
    echo "=========================================="

    cp -r $HOME/.bosh_init ./
  }
  trap finish ERR

  chmod +x ../bosh-init/bosh-init*
  echo "using bosh-init CLI version..."
  ../bosh-init/bosh-init* version

  echo "deploying BOSH..."
  ../bosh-init/bosh-init* deploy ${manifest_filename}

  trap - ERR
  finish
popd
