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

jobs:
- name: bosh
  networks:
  - name: default
  - name: my-vip
    static_ips: [__SOME-EIP__]

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
```

1. Set deployment

```
bosh-micro deployment my-micro/manifest.yml
```

1. Kick off a deploy

```
bosh-micro deploy ~/Downloads/bosh-aws-cpi-?.tgz ~/Downloads/light-bosh-stemcell-XXX-aws-xen-ubuntu-trusty-go_agent.tgz
```
