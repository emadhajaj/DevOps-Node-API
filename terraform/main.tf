# ── Data Sources ──────────────────────────────────────────────────────────────

# Get the latest Amazon Linux 2 AMI (don't hardcode AMI IDs)
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

# Get available AZs in the region
data "aws_availability_zones" "available" {
  state = "available"
}

# ── VPC and Networking ────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "devops-node-api-vpc" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = { Name = "devops-node-api-public" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "devops-node-api-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "devops-node-api-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ── Security Groups ───────────────────────────────────────────────────────────

# Jenkins server security group
resource "aws_security_group" "jenkins" {
  name        = "jenkins-sg"
  description = "Security group for Jenkins server"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "jenkins-sg" }

  lifecycle {
    ignore_changes = [ingress, egress]
  }
}

resource "aws_security_group_rule" "jenkins_ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.your_ip]
  description       = "SSH from admin"
  security_group_id = aws_security_group.jenkins.id
}

resource "aws_security_group_rule" "jenkins_ui_admin" {
  type              = "ingress"
  from_port         = 8080
  to_port           = 8080
  protocol          = "tcp"
  cidr_blocks       = [var.your_ip]
  description       = "Jenkins UI from admin"
  security_group_id = aws_security_group.jenkins.id
}

resource "aws_security_group_rule" "jenkins_webhook" {
  type              = "ingress"
  from_port         = 8080
  to_port           = 8080
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "GitHub webhook delivery"
  security_group_id = aws_security_group.jenkins.id
}

resource "aws_security_group_rule" "jenkins_agents" {
  type              = "ingress"
  from_port         = 50000
  to_port           = 50000
  protocol          = "tcp"
  cidr_blocks       = [var.your_ip]
  description       = "Jenkins agent connections"
  security_group_id = aws_security_group.jenkins.id
}

resource "aws_security_group_rule" "jenkins_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "All outbound traffic"
  security_group_id = aws_security_group.jenkins.id
}

# App server security group
resource "aws_security_group" "app" {
  name        = "app-sg"
  description = "Security group for the Node.js app"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "app-sg" }

  lifecycle {
    ignore_changes = [ingress, egress]
  }
}

resource "aws_security_group_rule" "app_api" {
  type              = "ingress"
  from_port         = 3000
  to_port           = 3000
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "App port public"
  security_group_id = aws_security_group.app.id
}

resource "aws_security_group_rule" "app_ssh_from_jenkins" {
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.jenkins.id
  description              = "SSH from Jenkins only"
  security_group_id        = aws_security_group.app.id
}

resource "aws_security_group_rule" "app_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "All outbound traffic"
  security_group_id = aws_security_group.app.id
}

# ── EC2 Instances ─────────────────────────────────────────────────────────────

# Jenkins server
resource "aws_instance" "jenkins" {
  ami                    = data.aws_ami.amazon_linux_2.id
  instance_type          = var.jenkins_instance_type
  key_name               = "devops-node-api-key"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.jenkins.id]

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -ex
    exec > /var/log/user-data.log 2>&1

    # ── System update ──────────────────────────────────────────────────────
    yum update -y

    # ── Git ───────────────────────────────────────────────────────────────
    yum install -y git

    # ── Docker ────────────────────────────────────────────────────────────
    amazon-linux-extras install docker -y
    systemctl start docker
    systemctl enable docker
    usermod -aG docker ec2-user

    # ── Java 11 ───────────────────────────────────────────────────────────
    amazon-linux-extras install java-openjdk11 -y

    # ── Jenkins ───────────────────────────────────────────────────────────
    wget -O /etc/yum.repos.d/jenkins.repo \
      https://pkg.jenkins.io/redhat-stable/jenkins.repo

    rpm --import \
      https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key

    yum install -y jenkins

    # ── Give Jenkins access to Docker ─────────────────────────────────────
    usermod -aG docker jenkins

    systemctl start jenkins
    systemctl enable jenkins

    # ── Completion marker (check with: cat /tmp/user-data-status) ─────────
    echo "USER_DATA_COMPLETE" > /tmp/user-data-status
  EOF
  )

  tags = { Name = "jenkins-server" }

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

# App server
resource "aws_instance" "app" {
  ami                    = data.aws_ami.amazon_linux_2.id
  instance_type          = var.app_instance_type
  key_name               = "devops-node-api-key"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app.id]

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -ex
    exec > /var/log/user-data.log 2>&1

    # ── System update ──────────────────────────────────────────────────────
    yum update -y

    # ── Docker ────────────────────────────────────────────────────────────
    amazon-linux-extras install docker -y
    systemctl start docker
    systemctl enable docker
    usermod -aG docker ec2-user

    # ── Completion marker ─────────────────────────────────────────────────
    echo "USER_DATA_COMPLETE" > /tmp/user-data-status
  EOF
  )

  tags = { Name = "app-server" }

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

