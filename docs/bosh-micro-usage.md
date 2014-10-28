## Experimental `bosh-micro` usage

!!! `bosh-micro` CLI is still being worked on !!!

To start experimenting with bosh-aws-cpi release and new bosh-micro cli:

1. Create a deployment directory

```
mkdir my-micro
```

1. Create `manifest.yml` inside deployment directory with following contents

```
---
name: my-micro

networks:
- name: my-vip
  type: vip
- name: default
  type: dynamic
  dns: [8.8.8.8, 4.4.4.4]
  cloud_properties: {subnet: __SOME-SUBNET__}

resource_pools:
- name: default
  cloud_properties:
    instance_type: m1.medium
    availability_zone: us-east-1c

cloud_provider:
  # Tells bosh-micro how to SSH into deployed VM
  ssh_tunnel:
    host: __SOME-EIP__
    port: 22
    user: vcap
    private_key: __SOME-PRIVATE-KEY-PATH__

  # Tells bosh-micro where to run registry on a user's machine while deploying
  registry:
    port: 6901
    host: 127.0.0.1
    username: registry-user
    password: registry-password

  # Tells bosh-micro how to contact remote agent
  mbus: https://mbus-user:mbus-password@__SOME-EIP__:6868

  properties:
    aws:
      access_key_id: __SOME-KEY__
      secret_access_key: __SOME-SECRET-KEY__
      default_key_name: bosh
      default_security_groups: ["bosh"]
      region: us-east-1
      ec2_private_key: __SOME-PRIVATE-KEY-PATH__

    # Tells CPI how agent should listen for requests
    agent:
      mbus: https://mbus-user:mbus-password@0.0.0.0:6868

    # Tells CPI how to contact registry
    registry:
      port: 6901
      host: 127.0.0.1
      username: registry-user
      password: registry-password

    blobstore:
      provider: local
      path: /var/vcap/micro_bosh/data/cache

    ntp: ["0.amazon.pool.ntp.org", "time1.google.com"]

jobs:
- name: bosh
  templates:
  - name: nats
  - name: redis
  - name: postgres
  - name: powerdns
  - name: blobstore
  - name: director
  - name: health_monitor
  - name: registry
  networks:
  - name: default
  - name: my-vip
    static_ips: [__SOME-EIP__]
  properties:
    aws:
      access_key_id: __SOME-KEY__
      secret_access_key: __SOME-SECRET-KEY__
      default_key_name: bosh
      default_security_groups: ["bosh"]
      ec2_endpoint: ec2.us-east-1.amazonaws.com
      region: us-east-1
    registry:
      address: __SOME-EIP__
      http:
        user: "admin"
        password: "admin"
        port: 25777
      db:
        user: "postgres"
        password: "postgres"
        host: "127.0.0.1"
        database: "bosh"
        port: 5432
        adapter: "postgres"
    nats:
      user: "nats"
      password: "nats"
      auth_timeout: 3
      address: "127.0.0.1"
    redis:
      address: "127.0.0.1"
      password: "redis"
      port: 25255
    postgres:
      user: "postgres"
      password: "postges"
      host: "127.0.0.1"
      database: "bosh"
      port: 5432
    blobstore:
      address: "127.0.0.1"
      director:
        user: "director"
        password: "director"
      agent:
        user: "agent"
        password: "agent"
      provider: "dav"
    director:
      address: "127.0.0.1"
      name: "micro"
      port: 25555
      db:
        user: "postgres"
        password: "postges"
        host: "127.0.0.1"
        database: "bosh"
        port: 5432
        adapter: "postgres"
      backend_port: 25556
    hm:
      http:
        user: "hm"
        password: "hm"
      director_account:
        user: "admin"
        password: "admin"
      intervals:
        log_stats: 300
        agent_timeout: 180
        rogue_agent_alert: 180
    dns:
      address: __SOME-EIP__
      domain_name: "microbosh"
      db:
        user: "postgres"
        password: "postges"
        host: "127.0.0.1"
        database: "bosh"
        port: 5432
        adapter: "postgres"
    ntp: []
```

1. Set deployment

```
bosh-micro deployment my-micro/manifest.yml
```

1. Kick off a deploy

```
bosh-micro deploy ~/Downloads/bosh-aws-cpi-?.tgz ~/Downloads/light-bosh-stemcell-XXX-aws-xen-ubuntu-trusty-go_agent.tgz
```
