###############################################################
# TP1 – Architecture EC2 en Haute Disponibilité
# Cours : SERVICES CLOUD AWS – Ing. BOGNI-DANCHI
#
# Composants :
#   - VPC Multi-AZ (eu-central-1a / 1b)
#   - EC2 via Auto Scaling Group
#   - Application Load Balancer
#   - Amazon RDS MySQL Multi-AZ
#   - Bucket S3
#   - Fonction Lambda
#   - Serveur VPN Pritunl
###############################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

###############################################################
# KEY PAIR SSH
###############################################################
resource "aws_key_pair" "deployer" {
  key_name   = "tp1-key"
  public_key = file("${path.module}/tp1-key.pub")
}

###############################################################
# AMI – Amazon Linux 2023 (dernière version)
###############################################################
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

###############################################################
# VPC MULTI-AZ
###############################################################
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "tp1-vpc" }
}

# ── Subnets publics ──────────────────────────────────────────
resource "aws_subnet" "public_az_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true
  tags = { Name = "public-az-a", Tier = "public" }
}

resource "aws_subnet" "public_az_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = true
  tags = { Name = "public-az-b", Tier = "public" }
}

# ── Subnets privés (RDS) ─────────────────────────────────────
resource "aws_subnet" "private_az_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "${var.aws_region}a"
  tags = { Name = "private-az-a", Tier = "private" }
}

resource "aws_subnet" "private_az_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "${var.aws_region}b"
  tags = { Name = "private-az-b", Tier = "private" }
}

###############################################################
# INTERNET GATEWAY + ROUTE TABLE
###############################################################
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "tp1-igw" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "public-rt" }
}

resource "aws_route_table_association" "pub_a" {
  subnet_id      = aws_subnet.public_az_a.id
  route_table_id = aws_route_table.public_rt.id
}
resource "aws_route_table_association" "pub_b" {
  subnet_id      = aws_subnet.public_az_b.id
  route_table_id = aws_route_table.public_rt.id
}

###############################################################
# SECURITY GROUPS
###############################################################

# ALB – HTTP public uniquement
resource "aws_security_group" "alb_sg" {
  name        = "tp1-alb-sg"
  description = "ALB : HTTP public"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "tp1-alb-sg" }
}

# EC2 App – reçoit depuis ALB et VPN
resource "aws_security_group" "app_sg" {
  name        = "tp1-app-sg"
  description = "EC2 : depuis ALB et VPN"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP depuis ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  ingress {
    description = "SSH depuis VPN"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "tp1-app-sg" }
}

# RDS – depuis EC2 uniquement
resource "aws_security_group" "rds_sg" {
  name        = "tp1-rds-sg"
  description = "RDS : depuis EC2"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MySQL depuis EC2"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "tp1-rds-sg" }
}

# VPN Pritunl
resource "aws_security_group" "vpn_sg" {
  name        = "tp1-vpn-sg"
  description = "Pritunl VPN"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Web UI HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "OpenVPN UDP"
    from_port   = 1194
    to_port     = 1194
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "Pritunl cluster"
    from_port   = 9700
    to_port     = 9700
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "SSH admin"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "tp1-vpn-sg" }
}

###############################################################
# APPLICATION LOAD BALANCER
###############################################################
resource "aws_lb" "alb" {
  name               = "tp1-alb"
  load_balancer_type = "application"
  subnets            = [aws_subnet.public_az_a.id, aws_subnet.public_az_b.id]
  security_groups    = [aws_security_group.alb_sg.id]
  tags               = { Name = "tp1-alb" }
}

resource "aws_lb_target_group" "tg" {
  name     = "tp1-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
  tags = { Name = "tp1-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

###############################################################
# LAUNCH TEMPLATE EC2 – Serveur web simple (TP1)
###############################################################
resource "aws_launch_template" "web" {
  name_prefix            = "tp1-web-"
  image_id               = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.deployer.key_name
  vpc_security_group_ids = [aws_security_group.app_sg.id]

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  user_data = base64encode(<<-EOF
#!/bin/bash
dnf update -y
dnf install -y httpd
systemctl start httpd
systemctl enable httpd

# Page de test avec identité du nœud
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
cat > /var/www/html/index.html <<HTML
<html><body>
<h1>TP1 – Serveur AWS HA</h1>
<p>Instance : $INSTANCE_ID</p>
<p>Zone : $AZ</p>
</body></html>
HTML
EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = { Name = "tp1-web-node" }
  }

  lifecycle { create_before_destroy = true }
}

###############################################################
# AUTO SCALING GROUP (Multi-AZ)
###############################################################
resource "aws_autoscaling_group" "asg" {
  name                      = "tp1-asg"
  desired_capacity          = 2
  min_size                  = 2
  max_size                  = 4
  vpc_zone_identifier       = [aws_subnet.public_az_a.id, aws_subnet.public_az_b.id]
  target_group_arns         = [aws_lb_target_group.tg.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  dynamic "tag" {
    for_each = {
      Name    = "tp1-asg-node"
      Project = "TP1-HA"
    }
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

# Scaling automatique sur CPU
resource "aws_autoscaling_policy" "cpu" {
  name                   = "tp1-cpu-policy"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 70.0
  }
}

###############################################################
# RDS MYSQL MULTI-AZ
###############################################################
resource "aws_db_subnet_group" "rds_subnets" {
  name       = "tp1-rds-subnets"
  subnet_ids = [aws_subnet.private_az_a.id, aws_subnet.private_az_b.id]
  tags       = { Name = "tp1-rds-subnets" }
}

resource "aws_db_instance" "mysql" {
  identifier              = "tp1-mysql"
  engine                  = "mysql"
  engine_version          = "8.0"
  instance_class          = "db.t3.micro"
  allocated_storage       = 20
  storage_type            = "gp2"
  db_name                 = "tp1db"
  username                = "admin"
  password                = var.db_password
  db_subnet_group_name    = aws_db_subnet_group.rds_subnets.name
  vpc_security_group_ids  = [aws_security_group.rds_sg.id]
  multi_az                = true          # HA RDS Multi-AZ
  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 7
  tags = { Name = "tp1-rds" }
}

###############################################################
# S3 BUCKET
###############################################################
resource "aws_s3_bucket" "storage" {
  bucket        = "tp1-storage-${random_id.bucket_suffix.hex}"
  force_destroy = true
  tags          = { Name = "tp1-s3" }
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket_versioning" "storage" {
  bucket = aws_s3_bucket.storage.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "storage" {
  bucket = aws_s3_bucket.storage.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "storage" {
  bucket                  = aws_s3_bucket.storage.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

###############################################################
# LAMBDA – Traitement asynchrone/événementiel
###############################################################
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/lambda.zip"
  source {
    content  = <<-PYTHON
import json, boto3, os

def handler(event, context):
    print("TP1 Lambda déclenchée :", json.dumps(event))
    s3 = boto3.client('s3')
    bucket = os.environ.get('S3_BUCKET', '')
    if bucket and event.get('Records'):
        for record in event['Records']:
            key = record.get('s3', {}).get('object', {}).get('key', '')
            print(f"Fichier reçu : s3://{bucket}/{key}")
    return {"statusCode": 200, "body": "OK"}
PYTHON
    filename = "lambda_function.py"
  }
}

resource "aws_iam_role" "lambda_role" {
  name = "tp1-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_s3" {
  name = "tp1-lambda-s3"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
      Resource = [aws_s3_bucket.storage.arn, "${aws_s3_bucket.storage.arn}/*"]
    }]
  })
}

resource "aws_lambda_function" "processor" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "tp1-processor"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.handler"
  runtime          = "python3.12"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      S3_BUCKET = aws_s3_bucket.storage.bucket
    }
  }
  tags = { Name = "tp1-lambda" }
}

# Déclencheur S3 → Lambda
resource "aws_s3_bucket_notification" "lambda_trigger" {
  bucket = aws_s3_bucket.storage.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.processor.arn
    events              = ["s3:ObjectCreated:*"]
  }
  depends_on = [aws_lambda_permission.s3_invoke]
}

resource "aws_lambda_permission" "s3_invoke" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.storage.arn
}

###############################################################
# VPN INSTANCE – Pritunl
###############################################################
resource "aws_instance" "vpn" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t2.micro"
  key_name                    = aws_key_pair.deployer.key_name
  subnet_id                   = aws_subnet.public_az_a.id
  vpc_security_group_ids      = [aws_security_group.vpn_sg.id]
  associate_public_ip_address = true
  source_dest_check           = false

  user_data = file("${path.module}/../scripts/vpn_userdata.sh")
  tags      = { Name = "tp1-pritunl-vpn" }
}

resource "aws_eip" "vpn" {
  instance = aws_instance.vpn.id
  domain   = "vpc"
  tags     = { Name = "tp1-vpn-eip" }
}

###############################################################
# OUTPUTS TP1
###############################################################
output "tp1_alb_url" {
  description = "URL du Load Balancer TP1"
  value       = "http://${aws_lb.alb.dns_name}"
}

output "tp1_vpn_ip" {
  description = "IP fixe du serveur VPN"
  value       = aws_eip.vpn.public_ip
}

output "tp1_vpn_console" {
  description = "Interface Pritunl"
  value       = "https://${aws_eip.vpn.public_ip}"
}

output "tp1_rds_endpoint" {
  description = "Endpoint RDS MySQL"
  value       = aws_db_instance.mysql.endpoint
}

output "tp1_s3_bucket" {
  description = "Nom du bucket S3"
  value       = aws_s3_bucket.storage.bucket
}

output "tp1_lambda_name" {
  description = "Nom de la fonction Lambda"
  value       = aws_lambda_function.processor.function_name
}
