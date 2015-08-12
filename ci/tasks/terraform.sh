#!/usr/bin/env bash

set -e -x

source bosh-cpi-release/ci/tasks/utils.sh

check_param aws_access_key_id
check_param aws_secret_access_key
check_param region_name
check_param base_os

export AWS_ACCESS_KEY_ID=${aws_access_key_id}
export AWS_SECRET_ACCESS_KEY=${aws_secret_access_key}
export AWS_DEFAULT_REGION=${region_name}

apt-get update
apt-get -y install python
curl -O https://bootstrap.pypa.io/get-pip.py
python get-pip.py
apt-get -y install groff
apt-get -y install jq
pip install awscli

#tear down previous director if it exists
previous_director_instance=$(jq '.current_vm_cid' director-state-file/${base_os}-director-manifest-state.json)
previous_security_group_id=$(jq '.modules[].resources["aws_security_group.bats_sg"].primary.id' ubuntu-bats.tfstate)
set +e

aws ec2 terminate-instances --instance-ids ${previous_director_instance//\"/}
aws ec2 delete-security-group --group-id ${previous_security_group_id//\"/}
set -e

desired_status="\"terminated\""
instance_status=$(aws ec2 describe-instance-status --instance-id i-1fc65ff6 | jq '.InstanceStatuses[].InstanceState.Name')
if [ -v "$instance_status" ]; then
  while [ "$desired_status" != "$instance_status" ]
  do
    instance_status=$(aws ec2 describe-instance-status --instance-id i-1fc65ff6 | jq '.InstanceStatuses[].InstanceState.Name')
    echo "pausing 20s for instance termination..."
    sleep 20s
  done
fi

#heredoc variables.tf
cat > "terraform.tfvars" <<EOF
access_key = "${aws_access_key_id}"
secret_key = "${aws_secret_access_key}"
build_id = "bats-${base_os}"
EOF

#copy tf file from assets to working directory
cp bosh-cpi-release/ci/assets/bosh-workspace.tf bosh-workspace.tf

state_file=${base_os}-bats.tfstate
export_file=terraform-${base_os}-exports.sh
tf_plan_file=${base_os}-bats.tfplan

#copy existing state file to working directory
cp terraform-state/${state_file} ${state_file}

/terraform/terraform destroy -force -state=${state_file}

# generates a plan
/terraform/terraform plan -out=${tf_plan_file}

# applies the plan, generates a state file
/terraform/terraform apply -state=${state_file} ${tf_plan_file}

# exports values into an exports file
echo -e "#!/usr/bin/env bash" >> $export_file
echo -e "export DIRECTOR=$(/terraform/terraform output -state=${state_file} director_vip)" >> $export_file
echo -e "export VIP=$(/terraform/terraform output -state=${state_file} bats_vip)" >> $export_file
echo -e "export SUBNET_ID=$(/terraform/terraform output -state=${state_file} subnet_id)" >> $export_file
echo -e "export SECURITY_GROUP_NAME=$(/terraform/terraform output -state=${state_file} security_group_name)" >> $export_file
echo -e "export AVAILABILITY_ZONE=$(/terraform/terraform output -state=${state_file} availability_zone)" >> $export_file
