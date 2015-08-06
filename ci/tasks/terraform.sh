#!/usr/bin/env bash

set -e -x

source bosh-cpi-release/ci/tasks/utils.sh

check_param aws_access_key_id
check_param aws_secret_access_key
check_param concourse_ip
check_param base_os
check_param security_group_trusted_ip

#heredoc .tf config
cat > "temp_tf_config.tf" <<EOF
variable "access_key" {"${aws_access_key_id}"}
variable "secret_key" {"${aws_secret_access_key}"}
variable "build_id" {"bats-${base_os}"}
variable "concourse_ip" {"${concourse_ip}"}
variable "security_group_trusted_ip" {"${security_group_trusted_ip}"}

provider "aws" {
    access_key = "${var.access_key}"
    secret_key = "${var.secret_key}"
    region = "us-east-1"
}

resource "aws_vpc" "vpc" {
    cidr_block = "10.0.0.0/16"

    tags {
        Name = "${var.build_id}"
    }
}

resource "aws_internet_gateway" "gw" {
    vpc_id = "${aws_vpc.vpc.id}"

    tags {
        Name = "${var.build_id}"
    }
}

resource "aws_route_table" "rt" {
    vpc_id = "${aws_vpc.vpc.id}"
    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = "${aws_internet_gateway.gw.id}"
    }

    tags {
        Name = "${var.build_id}"
    }
}

resource "aws_subnet" "sn" {
    vpc_id = "${aws_vpc.vpc.id}"
    cidr_block = "10.0.0.0/24"

    tags {
        Name = "${var.build_id}"
    }
}

resource "aws_route_table_association" "rta" {
    subnet_id = "${aws_subnet.sn.id}"
    route_table_id = "${aws_route_table.rt.id}"
}

resource "aws_security_group" "bats_sg" {
  name = "bats_sg-${var.build_id}"
  description = "allows local and concourse traffic"
  vpc_id = "${aws_vpc.vpc.id}"

  ingress {
      from_port = 0
      to_port = 65535
      protocol = "tcp"
      self = true
  }

  ingress {
      from_port = 22
      to_port = 22
      protocol = "tcp"
      cidr_blocks = ["${var.concourse_ip}/32"]
  }

  ingress {
      from_port = 22
      to_port = 22
      protocol = "tcp"
      cidr_blocks = ["${var.security_group_trusted_ip}/32"]
  }

  ingress {
      from_port = 6868
      to_port = 6868
      protocol = "tcp"
      cidr_blocks = ["${var.concourse_ip}/32"]
  }

  ingress {
      from_port = 6868
      to_port = 6868
      protocol = "tcp"
      cidr_blocks = ["${var.security_group_trusted_ip}/32"]
  }

  ingress {
      from_port = 25555
      to_port = 25555
      protocol = "tcp"
      cidr_blocks = ["${var.concourse_ip}/32"]
  }

  ingress {
      from_port = 25555
      to_port = 25555
      protocol = "tcp"
      cidr_blocks = ["${var.security_group_trusted_ip}/32"]
  }

  ingress {
      from_port = 0
      to_port = 65535
      protocol = "udp"
      self = true
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name = "${var.build_id}"
  }
}

resource "aws_eip" "director_vip" {
    vpc = true
}

resource "aws_eip" "bats_vip" {
    vpc = true
}

output "director_vip" {
    value = "${aws_eip.director_vip.public_ip}"
}

output "bats_vip" {
    value = "${aws_eip.bats_vip.public_ip}"
}

output "subnet_id" {
    value = "${aws_subnet.sn.id}"
}

output "security_group_name" {
    value = "${aws_security_group.bats_sg.name}"
}

output "availability_zone" {
    value = "${aws_subnet.sn.availability_zone}"
EOF

# generates a plan
/terraform/terraform plan -out=${base_os}-bats.tfplan

state_file=${base_os}-bats.tfstate
export_file=terraform-${base_os}-exports.sh

# applies the plan, generates a state file
/terraform/terraform apply -state=$state_file ${base_os}-bats.tfplan

# exports values into an exports file
echo -e "#!/usr/bin/env bash" >> $export_file
echo -e "export DIRECTOR=$(/terraform/terraform output -state=${state_file} director_vip)" >> $export_file
echo -e "export VIP=$(/terraform/terraform output -state=${state_file} bats_vip)" >> $export_file
echo -e "export SUBNET_ID=$(/terraform/terraform output -state=${state_file} subnet_id)" >> $export_file
echo -e "export SECURITY_GROUP_NAME=$(/terraform/terraform output -state=${state_file} security_group_name)" >> $export_file
echo -e "export AVAILABILITY_ZONE=$(/terraform/terraform output -state=${state_file} availability_zone)" >> $export_file
