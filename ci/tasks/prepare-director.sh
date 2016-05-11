#!/usr/bin/env bash

set -e

# environment
: ${BOSH_DIRECTOR_USERNAME:?}
: ${BOSH_DIRECTOR_PASSWORD:?}
: ${AWS_ACCESS_KEY:?}
: ${AWS_SECRET_KEY:?}
: ${AWS_REGION_NAME:?}
: ${PUBLIC_KEY_NAME:?}
: ${PRIVATE_KEY_DATA:?}
: ${USE_REDIS:=false}

# inputs
# paths will be resolved in a separate task so use relative paths
BOSH_RELEASE_URI="file://$(echo bosh-release/*.tgz)"
CPI_RELEASE_URI="file://$(echo cpi-release/*.tgz)"
STEMCELL_URI="file://$(echo stemcell/*.tgz)"

# outputs
output_dir="$(realpath director-config)"

metadata=$(cat environment/metadata)

# configuration
: ${SECURITY_GROUP:=$(       echo ${metadata} | jq --raw-output ".SecurityGroupID" )}
: ${DIRECTOR_EIP:=$(         echo ${metadata} | jq --raw-output ".DirectorEIP" )}
: ${SUBNET_ID:=$(            echo ${metadata} | jq --raw-output ".PublicSubnetID" )}
: ${AVAILABILITY_ZONE:=$(    echo ${metadata} | jq --raw-output ".AvailabilityZone" )}
: ${AWS_NETWORK_CIDR:=$(     echo ${metadata} | jq --raw-output ".PublicCIDR" )}
: ${AWS_NETWORK_GATEWAY:=$(  echo ${metadata} | jq --raw-output ".PublicGateway" )}
: ${AWS_NETWORK_DNS:=$(      echo ${metadata} | jq --raw-output ".DNS" )}
: ${DIRECTOR_STATIC_IP:=$(   echo ${metadata} | jq --raw-output ".DirectorStaticIP" )}
: ${BLOBSTORE_BUCKET_NAME:=$(echo ${metadata} | jq --raw-output ".BlobstoreBucket" )}

# keys
shared_key="shared.pem"
echo "${PRIVATE_KEY_DATA}" > "${output_dir}/${shared_key}"

redis_job=""
if [ "${USE_REDIS}" == true ]; then
  redis_job="- {name: redis, release: bosh}"
fi

# env file generation
cat > "${output_dir}/director.env" <<EOF
#!/usr/bin/env bash

export BOSH_DIRECTOR_IP=${DIRECTOR_EIP}
export BOSH_DIRECTOR_USERNAME=${BOSH_DIRECTOR_USERNAME}
export BOSH_DIRECTOR_PASSWORD=${BOSH_DIRECTOR_PASSWORD}
EOF

# manifest generation
cat > "${output_dir}/director.yml" <<EOF
---
name: certification-director

releases:
  - name: bosh
    url: ${BOSH_RELEASE_URI}
  - name: bosh-aws-cpi
    url: ${CPI_RELEASE_URI}

resource_pools:
  - name: default
    network: private
    stemcell:
      url: ${STEMCELL_URI}
    cloud_properties:
      instance_type: m3.medium
      availability_zone: ${AVAILABILITY_ZONE}
      ephemeral_disk:
        size: 25000
        type: gp2

disk_pools:
  - name: default
    disk_size: 25_000
    cloud_properties: {type: gp2}

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

jobs:
  - name: bosh
    instances: 1

    templates:
      - {name: nats, release: bosh}
      - {name: postgres, release: bosh}
      - {name: blobstore, release: bosh}
      - {name: director, release: bosh}
      - {name: health_monitor, release: bosh}
      - {name: powerdns, release: bosh}
      - {name: registry, release: bosh}
      - {name: aws_cpi, release: bosh-aws-cpi}
      ${redis_job}

    resource_pool: default
    persistent_disk_pool: default

    networks:
      - name: private
        static_ips: [${DIRECTOR_STATIC_IP}]
        default: [dns, gateway]
      - name: public
        static_ips: [${DIRECTOR_EIP}]

    properties:
      nats:
        address: 127.0.0.1
        user: nats
        password: nats-password

      postgres: &db
        host: 127.0.0.1
        user: postgres
        password: postgres-password
        database: bosh
        adapter: postgres

      # required for some upgrade paths
      redis:
        listen_addresss: 127.0.0.1
        address: 127.0.0.1
        password: redis-password

      registry:
        address: ${DIRECTOR_STATIC_IP}
        host: ${DIRECTOR_STATIC_IP}
        db: *db
        http: {user: ${BOSH_DIRECTOR_USERNAME}, password: ${BOSH_DIRECTOR_PASSWORD}, port: 25777}
        username: ${BOSH_DIRECTOR_USERNAME}
        password: ${BOSH_DIRECTOR_PASSWORD}
        port: 25777

      blobstore:
        director: {user: director, password: director-password}
        agent: {user: agent, password: agent-password}
        provider: s3
        s3_region: ${AWS_REGION_NAME}
        bucket_name: ${BLOBSTORE_BUCKET_NAME}
        s3_signature_version: '4'
        access_key_id: ${AWS_ACCESS_KEY}
        secret_access_key: ${AWS_SECRET_KEY}

      director:
        address: 127.0.0.1
        name: bats-director
        db: *db
        cpi_job: aws_cpi
        user_management:
          provider: local
          local:
            users:
              - {name: ${BOSH_DIRECTOR_USERNAME}, password: ${BOSH_DIRECTOR_PASSWORD}}

      hm:
        http: {user: hm, password: hm-password}
        director_account: {user: ${BOSH_DIRECTOR_USERNAME}, password: ${BOSH_DIRECTOR_PASSWORD}}

      dns:
        recursor: 10.0.0.2
        address: 127.0.0.1
        db: *db

      agent: {mbus: "nats://nats:nats-password@${DIRECTOR_STATIC_IP}:4222"}

      ntp: &ntp
        - 0.north-america.pool.ntp.org
        - 1.north-america.pool.ntp.org

      aws: &aws-config
        default_key_name: ${PUBLIC_KEY_NAME}
        default_security_groups: ["${SECURITY_GROUP}"]
        region: "${AWS_REGION_NAME}"
        access_key_id: ${AWS_ACCESS_KEY}
        secret_access_key: ${AWS_SECRET_KEY}

cloud_provider:
  template: {name: aws_cpi, release: bosh-aws-cpi}

  ssh_tunnel:
    host: ${DIRECTOR_EIP}
    port: 22
    user: vcap
    private_key: ${shared_key}

  mbus: "https://mbus:mbus-password@${DIRECTOR_EIP}:6868"

  properties:
    aws: *aws-config

    # Tells CPI how agent should listen for requests
    agent: {mbus: "https://mbus:mbus-password@0.0.0.0:6868"}

    blobstore:
      provider: local
      path: /var/vcap/micro_bosh/data/cache

    ntp: *ntp
EOF
