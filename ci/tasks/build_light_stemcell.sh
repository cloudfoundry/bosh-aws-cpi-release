#!/usr/bin/env bash

set -e

source bosh-cpi-release/ci/tasks/utils.sh

check_param aws_access_key_id
check_param aws_secret_access_key
check_param region_name
check_param vm_ami
check_param vm_user
check_param private_key_data
check_param public_key_name
check_param vm_name
check_param stack_name

export AWS_ACCESS_KEY_ID=${aws_access_key_id}
export AWS_SECRET_ACCESS_KEY=${aws_secret_access_key}
export AWS_DEFAULT_REGION=${region_name}
stack_info=$(get_stack_info $stack_name)

private_key_file=$PWD/vm_private_key.pem
echo "${private_key_data}" > ${private_key_file}
chmod go-r ${private_key_file}

export VAGRANT_CONFIG_FILE="${PWD}/vagrant_light_stemcell_builder_config.json"
cat > "${VAGRANT_CONFIG_FILE}"<<EOF
{
  "AWS_ACCESS_KEY_ID": "${aws_access_key_id}",
  "AWS_SECRET_ACCESS_KEY": "${aws_secret_access_key}",
  "AWS_DEFAULT_REGION": "${region_name}",
  "VM_AMI": "${vm_ami}",
  "VM_USER": "${vm_user}",
  "VM_NAME": "${vm_name}",
  "BOSH_SRC_PATH": "${PWD}/bosh-src",
  "AWS_SECURITY_GROUP": "$(get_stack_info_of "${stack_info}" "SecurityGroupID")",
  "VM_KEYPAIR_NAME": "${public_key_name}",
  "AWS_SUBNET_ID": "$(get_stack_info_of "${stack_info}" "SubnetID")",
  "AWS_ENDPOINT": "https://$(aws ec2 describe-regions | jq -r --arg key ${region_name} '.Regions[] | select(.RegionName=="\($key)").Endpoint')",
  "VM_PRIVATE_KEY_FILE": "${private_key_file}"
}
EOF

workspace="${PWD}/bosh-cpi-release/ci/light_stemcell_builder"
out_dir="${PWD}/out"

full_stemcell_url=$(cat bosh-aws-full-stemcell/url | awk '{ gsub(/light-/, ""); print }')
full_stemcell_name=china-$(echo ${full_stemcell_url} | grep -o "[^/]*$")

pushd ${workspace}
  vagrant box add dummy https://github.com/mitchellh/vagrant-aws/raw/master/dummy.box
  vagrant up --provider=aws
  vagrant ssh << EOF
    wget ${full_stemcell_url} -O /home/${vm_user}/${full_stemcell_name}
    cd /bosh/bosh-stemcell
    bundle exec rake stemcell:build_light[/home/${vm_user}/${full_stemcell_name},hvm]
EOF
  mkdir -p ${out_dir}
  vagrant ssh-config > ./vagrant.ssh.config
  scp -F vagrant.ssh.config default:/home/${vm_user}/*light*.tgz ${out_dir}/
  vagrant destroy -f
popd
