
# Create a new classic load balancer
resource "aws_elb" "e2e" {
  listener {
    instance_port = 80
    instance_protocol = "http"
    lb_port = 80
    lb_protocol = "http"
  }

  subnets = ["${aws_subnet.manual.id}"]

  tags {
    Name = "${var.env_name}-e2e"
  }
}

resource "aws_iam_role_policy" "e2e" {
  name = "${var.env_name}-policy"
  role = "${aws_iam_role.e2e.id}"
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Action": [
      "ec2:AssociateAddress",
      "ec2:AttachVolume",
      "ec2:CreateVolume",
      "ec2:DeleteSnapshot",
      "ec2:DeleteVolume",
      "ec2:Describe*",
      "ec2:DetachVolume",
      "ec2:CreateSnapshot",
      "ec2:CreateTags",
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:RequestSpotInstances",
      "ec2:CancelSpotInstanceRequests",
      "ec2:DeregisterImage",
      "ec2:DescribeImages",
      "ec2:RegisterImage"
    ],
    "Effect": "Allow",
		"Resource": "*"
  },
  {
    "Effect": "Allow",
    "Action": "elasticloadbalancing:*",
		"Resource": "*"
  }]
}
EOF
}

resource "aws_iam_instance_profile" "e2e" {
  role = "${aws_iam_role.e2e.name}"
}

resource "aws_iam_role" "e2e" {
  name_prefix = "${var.env_name}"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

# Used by end-2-end tests
output "iam_instance_profile" {
  value = "${aws_iam_instance_profile.e2e.name}"
}
output "e2e_elb_name" {
  value = "${aws_elb.e2e.id}"
}

