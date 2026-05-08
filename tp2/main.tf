###############################################################
# TP2 – Déploiement Applicatif Automatisé en HA
# Cours : SERVICES CLOUD AWS – Ing. BOGNI-DANCHI
#
# Composants :
#   - Réutilise le VPC / VPN du TP1 via data sources
#   - ASG avec Launch Template Odoo 19 + Docker Compose
#   - ALB avec sticky sessions (requis pour Odoo)
#   - PostgreSQL réplication logique Master-Master
#   - Pritunl VPN pour cloud hybride
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
# RÉCUPÉRATION DE L'INFRASTRUCTURE TP1 (data sources)
###############################################################
data "aws_vpc" "main" {
  tags = { Name = "tp1-vpc" }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  tags = { Tier = "public" }
}

data "aws_key_pair" "deployer" {
  key_name = "tp1-key"
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

###############################################################
# SECURITY GROUPS TP2
###############################################################

# ALB Odoo – HTTP public
resource "aws_security_group" "tp2_alb_sg" {
  name        = "tp2-alb-sg"
  description = "ALB Odoo : HTTP public"
  vpc_id      = data.aws_vpc.main.id

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
  tags = { Name = "tp2-alb-sg" }
}

# EC2 Odoo – depuis ALB + VPN + réplication PG inter-nœuds
resource "aws_security_group" "tp2_odoo_sg" {
  name        = "tp2-odoo-sg"
  description = "Odoo nodes : ALB + VPN + PG replication"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description     = "Odoo depuis ALB"
    from_port       = 8069
    to_port         = 8069
    protocol        = "tcp"
    security_groups = [aws_security_group.tp2_alb_sg.id]
  }
  ingress {
    description     = "Longpolling depuis ALB"
    from_port       = 8072
    to_port         = 8072
    protocol        = "tcp"
    security_groups = [aws_security_group.tp2_alb_sg.id]
  }
  ingress {
    description = "SSH depuis VPC (VPN)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }
  ingress {
    description = "PostgreSQL replication inter-noeuds"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "tp2-odoo-sg" }
}

###############################################################
# APPLICATION LOAD BALANCER – ODOO
###############################################################
resource "aws_lb" "odoo_alb" {
  name               = "tp2-odoo-alb"
  load_balancer_type = "application"
  subnets            = data.aws_subnets.public.ids
  security_groups    = [aws_security_group.tp2_alb_sg.id]
  tags               = { Name = "tp2-odoo-alb" }
}

resource "aws_lb_target_group" "odoo_tg" {
  name        = "tp2-odoo-tg"
  port        = 8069
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/web/health"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  # ⚠️ Sticky sessions OBLIGATOIRES pour Odoo (sessions utilisateur)
  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = true
  }
  tags = { Name = "tp2-odoo-tg" }
}

resource "aws_lb_listener" "odoo_http" {
  load_balancer_arn = aws_lb.odoo_alb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.odoo_tg.arn
  }
}

###############################################################
# LAUNCH TEMPLATE – Odoo + Docker Compose (bootstrap complet)
###############################################################
resource "aws_launch_template" "odoo" {
  name_prefix            = "tp2-odoo-"
  image_id               = data.aws_ami.amazon_linux.id
  instance_type          = var.odoo_instance_type
  key_name               = data.aws_key_pair.deployer.key_name
  vpc_security_group_ids = [aws_security_group.tp2_odoo_sg.id]

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30   # Docker images + données Odoo
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/../scripts/odoo_userdata.sh", {
    db_password     = var.db_password
    repl_password = var.repl_password
    odoo_admin_pass = var.odoo_admin_pass
    vpc_cidr        = data.aws_vpc.main.cidr_block
  }))

  tag_specifications {
    resource_type = "instance"
    tags = { Name = "tp2-odoo-node", Role = "odoo-master" }
  }

  lifecycle { create_before_destroy = true }
}

###############################################################
# AUTO SCALING GROUP – Odoo (2 nœuds, 1 par AZ)
###############################################################
resource "aws_autoscaling_group" "odoo_asg" {
  name                      = "tp2-odoo-asg"
  desired_capacity          = 2
  min_size                  = 2
  max_size                  = 4
  vpc_zone_identifier       = data.aws_subnets.public.ids
  target_group_arns         = [aws_lb_target_group.odoo_tg.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300   # Odoo prend ~3-5 min à démarrer

  launch_template {
    id      = aws_launch_template.odoo.id
    version = "$Latest"
  }

  dynamic "tag" {
    for_each = {
      Name    = "tp2-odoo-node"
      Project = "TP2-HA"
      Role    = "odoo-master"
    }
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

resource "aws_autoscaling_policy" "odoo_cpu" {
  name                   = "tp2-odoo-cpu"
  autoscaling_group_name = aws_autoscaling_group.odoo_asg.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 70.0
  }
}

###############################################################
# OUTPUTS TP2
###############################################################
output "tp2_odoo_url" {
  description = "URL d'accès à Odoo via ALB"
  value       = "http://${aws_lb.odoo_alb.dns_name}"
}

output "tp2_odoo_alb_dns" {
  description = "DNS brut de l'ALB"
  value       = aws_lb.odoo_alb.dns_name
}
