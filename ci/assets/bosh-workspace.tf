variable "access_key" {}
variable "secret_key" {}
variable "build_id" {}

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
      cidr_blocks = ["0.0.0.0/32"]
  }

  ingress {
      from_port = 22
      to_port = 22
      protocol = "tcp"
      cidr_blocks = ["0.0.0.0/32"]
  }

  ingress {
      from_port = 6868
      to_port = 6868
      protocol = "tcp"
      cidr_blocks = ["0.0.0.0/32"]
  }

  ingress {
      from_port = 6868
      to_port = 6868
      protocol = "tcp"
      cidr_blocks = ["0.0.0.0/32"]
  }

  ingress {
      from_port = 25555
      to_port = 25555
      protocol = "tcp"
      cidr_blocks = ["0.0.0.0/32"]
  }

  ingress {
      from_port = 25555
      to_port = 25555
      protocol = "tcp"
      cidr_blocks = ["0.0.0.0/32"]
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
}
