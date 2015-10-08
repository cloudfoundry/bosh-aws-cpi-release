#!/usr/bin/env bash

set -e

source bosh-cpi-release/ci/tasks/utils.sh

check_param aws_access_key_id
check_param aws_secret_access_key
check_param region_name
check_param stack_name
check_param private_key_data

export AWS_ACCESS_KEY_ID=${aws_access_key_id}
export AWS_SECRET_ACCESS_KEY=${aws_secret_access_key}
export AWS_DEFAULT_REGION=${region_name}

stack_info=$(get_stack_info $stack_name)
downloader_eip=$(get_stack_info_of "$stack_info" "DownloaderCNEIP")

stemcell_name=bosh-aws-xen-ubuntu-trusty-go_agent
private_key=${PWD}/bats.pem

echo "${private_key_data}" > ${private_key}
chmod go-r ${private_key}
eval $(ssh-agent)
ssh-add ${private_key}

available_stemcells=$(curl --retry 5 -L -s -f https://bosh.io/api/v1/stemcells/${stemcell_name})
stemcell=$(echo ${available_stemcells} | jq -r ".[0] | .regular // .light")
echo "selected stemcell ${stemcell}"
latest_url=$(echo ${stemcell} | jq -r '.url')
latest_md5=$(echo ${stemcell} | jq -r '.md5')

echo "Downloading stemcell on remote machine..."

ssh ec2-user@${downloader_eip} -o StrictHostKeyChecking=no -T \
"curl -o stemcell.tgz --fail --show-error ${latest_url}"

echo "Checking md5 hash of downloaded stemcell..."

ssh ec2-user@${downloader_eip} -o StrictHostKeyChecking=no -T \
"echo '${latest_md5} stemcell.tgz' | md5sum -c -"
