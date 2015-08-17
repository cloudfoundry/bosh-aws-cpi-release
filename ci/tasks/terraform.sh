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

#copy tf file from assets to working directory
cp bosh-cpi-release/ci/assets/bosh-workspace.tf bosh-workspace.tf

state_file=${base_os}-bats.tfstate
export_file=terraform-${base_os}-exports.sh
tf_plan_file=${base_os}-bats.tfplan

#copy existing state file to working directory
cp terraform-state/${state_file} ${state_file}

#tear down previous director if it exists
previous_director_instance=$(jq '.current_vm_cid' director-state-file/${base_os}-director-manifest-state.json)
previous_security_group_id=$(jq '.modules[].resources["aws_security_group.bats_sg"].primary.id' ${state_file})
previous_director_instance=${previous_director_instance//\"/}
set +e

instance_status=$(aws ec2 terminate-instances --instance-ids ${previous_director_instance} | jq '.TerminatingInstances[].CurrentState.Name')

desired_status="\"terminated\""
timeout=0
while [ "$desired_status" != "$instance_status" ] && [ ! -z "$instance_status" ]  &&  [ "$timeout" -lt 300 ]
do
  instance_status=$(aws ec2 terminate-instances --instance-ids ${previous_director_instance} | jq '.TerminatingInstances[].CurrentState.Name')
  echo "pausing 20s for instance termination..."
  sleep 20s
  timeout=$((timeout + 20))
done

aws ec2 delete-security-group --group-id ${previous_security_group_id//\"/}
set -e

#heredoc variables.tf
cat > "terraform.tfvars" <<EOF
access_key = "${aws_access_key_id}"
secret_key = "${aws_secret_access_key}"
build_id = "bats-${base_os}"
EOF

set +e
/terraform/terraform destroy -force -state=${state_file}
status=$?
set -e
#sometimes terraform is slow and needs to retry
if [ "${status}" != "0" ]; then
  /terraform/terraform destroy -force -state=${state_file}
fi

# generates a plan
/terraform/terraform plan -out=${tf_plan_file}

# applies the plan, generates a state file
set +e
/terraform/terraform apply -state=${state_file} ${tf_plan_file}
status=$?
set -e
if [ "${status}" != "0" ]; then
  /terraform/terraform apply -state=${state_file} ${tf_plan_file}
fi

# exports values into an exports file
echo -e "#!/usr/bin/env bash" >> $export_file
echo -e "export DIRECTOR=$(/terraform/terraform output -state=${state_file} director_vip)" >> $export_file
echo -e "export VIP=$(/terraform/terraform output -state=${state_file} bats_vip)" >> $export_file
echo -e "export SUBNET_ID=$(/terraform/terraform output -state=${state_file} subnet_id)" >> $export_file
echo -e "export SECURITY_GROUP_NAME=$(/terraform/terraform output -state=${state_file} security_group_name)" >> $export_file
echo -e "export AVAILABILITY_ZONE=$(/terraform/terraform output -state=${state_file} availability_zone)" >> $export_file
