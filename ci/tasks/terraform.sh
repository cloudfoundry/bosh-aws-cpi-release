#!/usr/bin/env bash

set -e -x

source bosh-cpi-release/ci/tasks/utils.sh

check_param aws_access_key_id
check_param aws_secret_access_key
check_param base_os

#copy tf template file from cpi-release directory
cp bosh-cpi-release/ci/assets/bosh-workspace.tf terraform-state

export_file=terraform-${base_os}-exports.sh

cd terraform-state

state_file=${base_os}-bats.tfstate

#heredoc variables.tf
cat > "terraform.tfvars" <<EOF
access_key = "${aws_access_key_id}"
secret_key = "${aws_secret_access_key}"
build_id = "bats-${base_os}"
EOF

/terraform/terraform destroy -force -state=$state_file

# applies the plan, generates a state file
/terraform/terraform apply -state=$state_file

# exports values into an exports file
echo -e "#!/usr/bin/env bash" >> $export_file
echo -e "export DIRECTOR=$(/terraform/terraform output -state=${state_file} director_vip)" >> $export_file
echo -e "export VIP=$(/terraform/terraform output -state=${state_file} bats_vip)" >> $export_file
echo -e "export SUBNET_ID=$(/terraform/terraform output -state=${state_file} subnet_id)" >> $export_file
echo -e "export SECURITY_GROUP_NAME=$(/terraform/terraform output -state=${state_file} security_group_name)" >> $export_file
echo -e "export AVAILABILITY_ZONE=$(/terraform/terraform output -state=${state_file} availability_zone)" >> $export_file
