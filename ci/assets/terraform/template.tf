variable "access_key" {}
variable "secret_key" {}
variable "role_arn" {}
variable "session_token" {
  default = ""
}
variable "region" {}
variable "env_name" {}
variable "public_key" {}

provider "aws" {
  access_key = var.access_key
  secret_key = var.secret_key
  token = var.session_token
  region = var.region
  assume_role {
    role_arn = var.role_arn
  }
}

data "aws_availability_zones" "available" {}

# Create a VPC to launch our instances into
resource "aws_vpc" "default" {
  assign_generated_ipv6_cidr_block = true
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = var.env_name
  }
}

# Create an internet gateway to give our subnet access to the outside world
resource "aws_internet_gateway" "default" {
  vpc_id = aws_vpc.default.id
  tags = {
    Name = var.env_name
  }
}

resource "aws_route_table" "default" {
  vpc_id = aws_vpc.default.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.default.id
  }

  tags = {
    Name = var.env_name
  }
}

resource "aws_route_table_association" "a" {
  subnet_id = aws_subnet.default.id
  route_table_id = aws_route_table.default.id
}

resource "aws_route_table_association" "c" {
  subnet_id = aws_subnet.manual.id
  route_table_id = aws_route_table.default.id
}

resource "aws_route_table_association" "b" {
  subnet_id = aws_subnet.backup.id
  route_table_id = aws_route_table.default.id
}

resource "aws_subnet" "default" {
  vpc_id = aws_vpc.default.id
  cidr_block = cidrsubnet(aws_vpc.default.cidr_block, 8, 0)
  ipv6_cidr_block = cidrsubnet(aws_vpc.default.ipv6_cidr_block, 8, 1)
  depends_on = [ aws_internet_gateway.default ]
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = var.env_name
  }

  map_public_ip_on_launch = true
}

resource "aws_subnet" "backup" {
  vpc_id = aws_vpc.default.id
  cidr_block = cidrsubnet(aws_vpc.default.cidr_block, 8, 2)
  ipv6_cidr_block = cidrsubnet(aws_vpc.default.ipv6_cidr_block, 8, 3)
  depends_on = [ aws_internet_gateway.default ]
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name = var.env_name
  }
}

resource "aws_subnet" "manual" {
  vpc_id = aws_vpc.default.id
  cidr_block = cidrsubnet(aws_vpc.default.cidr_block, 8, 4)
  ipv6_cidr_block = cidrsubnet(aws_vpc.default.ipv6_cidr_block, 8, 5)
  depends_on = [ aws_internet_gateway.default ]
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = var.env_name
  }

  map_public_ip_on_launch = true
}

resource "aws_network_acl" "allow_all" {
  vpc_id = aws_vpc.default.id
  subnet_ids = [
    aws_subnet.default.id,
    aws_subnet.backup.id,
    aws_subnet.manual.id
  ]

  egress {
    protocol = "-1"
    rule_no = 2
    action = "allow"
    cidr_block = "0.0.0.0/0"
    from_port = 0
    to_port = 0
  }

  ingress {
    protocol = "-1"
    rule_no = 1
    action = "allow"
    cidr_block = "0.0.0.0/0"
    from_port = 0
    to_port = 0
  }

  tags = {
    Name = var.env_name
  }
}

resource "aws_security_group" "allow_all" {
  vpc_id = aws_vpc.default.id
  name = "allow_all-${var.env_name}"
  description = "Allow all inbound and outgoing traffic"

  ingress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = [
      "0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = [
      "0.0.0.0/0"]
  }

  tags = {
    Name = var.env_name
  }
}

resource "aws_eip" "director" {
  vpc = true
}

resource "aws_eip" "deployment" {
  vpc = true
}

# Create a new classic load balancer
resource "aws_elb" "default" {
  listener {
    instance_port = 80
    instance_protocol = "http"
    lb_port = 80
    lb_protocol = "http"
  }

  subnets = [aws_subnet.default.id]

  tags = {
    Name = var.env_name
  }
}

# Create a new application load balancer
resource "aws_alb" "default" {
  subnets = [
    aws_subnet.default.id,
    aws_subnet.backup.id
  ]

  tags = {
    Name = var.env_name
  }
}

resource "aws_alb_target_group" "default" {
  name = var.env_name
  port = "80"
  protocol = "HTTP"
  vpc_id = aws_vpc.default.id
  health_check {
    interval = 5
    timeout = 4
    path  = "/"
    matcher  = "200"
  }

  tags = {
    Name = var.env_name
  }
}

resource "aws_alb_listener" "default" {
  load_balancer_arn = aws_alb.default.arn
  port = "80"
  protocol = "HTTP"

  default_action {
    target_group_arn = aws_alb_target_group.default.arn
    type = "forward"
  }
}

resource "aws_vpc_endpoint" "private-s3" {
  vpc_id = aws_vpc.default.id
  service_name = "com.amazonaws.${var.region}.s3"
  route_table_ids = [
    aws_route_table.default.id]
}

resource "aws_s3_bucket" "blobstore" {
  bucket = "cpi-pipeline-blobstore-${var.env_name}-${var.region}"
  force_destroy = true
}

resource "aws_key_pair" "director" {
  key_name   = var.env_name
  public_key = var.public_key
}

output "vpc_id" {
  value = aws_vpc.default.id
}
output "region" {
  value = var.region
}

# Used by bats
output "default_key_name" {
  value = aws_key_pair.director.key_name
}
output "default_security_groups" {
  value = [aws_security_group.allow_all.id]
}
output "external_ip" {
  value = aws_eip.director.public_ip
}
output "az" {
  value = aws_subnet.default.availability_zone
}
output "subnet_id" {
  value = aws_subnet.default.id
}
output "manual_subnet_id" {
  value = aws_subnet.manual.id
}
output "internal_cidr" {
  value = aws_vpc.default.cidr_block
}
output "internal_gw" {
  value = cidrhost(aws_vpc.default.cidr_block, 1)
}
output "dns_recursor_ip" {
  value = cidrhost(aws_vpc.default.cidr_block, 2)
}
output "internal_ip" {
  value = cidrhost(aws_vpc.default.cidr_block, 6)
}
output "reserved_range" {
  value = "${cidrhost(aws_vpc.default.cidr_block, 2)}-${cidrhost(aws_vpc.default.cidr_block, 9)}"
}
output "static_range" {
  value = "${cidrhost(aws_vpc.default.cidr_block, 10)}-${cidrhost(aws_vpc.default.cidr_block, 30)}"
}
output "bats_eip" {
  value = aws_eip.deployment.public_ip
}
output "network_static_ip_1" {
  value = cidrhost(aws_vpc.default.cidr_block, 29)
}
output "network_static_ip_2" {
  value = cidrhost(aws_vpc.default.cidr_block, 30)
}

# Used by integration tests
output "manual_static_ipv6" {
  # workaround: v0.9.5 cidrhost() does not work correctly for IPv6
  value = format("%s4", cidrhost(aws_subnet.manual.ipv6_cidr_block, 0))
}
output "elb" {
  value = aws_elb.default.id
}
output "alb" {
  value = aws_alb.default.id
}
output "alb_target_group" {
  value = aws_alb_target_group.default.name
}
output "blobstore_bucket" {
  value = aws_s3_bucket.blobstore.id
}
output "advertised_route_table" {
  value = aws_route_table.default.id
}
