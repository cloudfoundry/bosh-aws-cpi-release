#!/usr/bin/env bash

set -e

source bosh-cpi-release/ci/tasks/utils.sh


check_param aws_access_key_id
check_param aws_secret_access_key
check_param vm_ami
check_param vm_user
check_param private_key_data
check_param vm_vm_name
check_param stack_name


source /etc/profile.d/chruby.sh
chruby 2.1.2

stack_info=$(get_stack_info $stack_name)

export AWS_ACCESS_KEY_ID=${aws_access_key_id}
export AWS_SECRET_ACCESS_KEY=${aws_secret_access_key}
export VM_AMI=${vm_ami}
export VM_USER=${vm_user}
export VM_VM_NAME=${vm_vm_name}
export BOSH_SRC_PATH=${PWD}/${bosh-src}
export AWS_SECURITY_GROUP=$(get_stack_info_of "${stack_info}" "SecurityGroupID")
export VM_KEYPAIR_NAME=$(get_stack_info_of "${stack_info}" "VMKeyPairName")
export AWS_SUBNET_ID=$(get_stack_info_of "${stack_info}" "SubnetID")
export AWS_REGION=$(get_stack_info_of "${stack_info}" "RegionName")
export AWS_ENDPOINT=$(get_stack_info_of "${stack_info}" "RegionEndpoint")


private_key=$PWD/vm_private_key.pem
echo "${private_key_data}" > ${private_key}
chmod go-r ${private_key}
eval $(ssh-agent)
ssh-add ${private_key}

workspace="${PWD}/bosh-cpi-release/ci/light_stemcell_builder"
out_dir="${PWD}/out"
full_stemcell_name=china-$(cat bosh-aws-full-stemcell/url | grep -o "[^/]*$")

pushd ${workspace}
  vagrant up --provider=aws
  vagrant ssh-config > ./vagrant.ssh.config
  scp -F vagrant.ssh.config bosh-aws-full-stemcell/stemcell.tgz default:~/${full_stemcell_name}
  vagrant ssh -c "cd /bosh/bosh-stemcell && bundle exec rake stemcell:build_light[~/${full_stemcell_name},hvm]"
  mkdir -p ${out_dir}
  scp -F vagrant.ssh.config default:~/*light*.tgz ${out_dir}
popd
