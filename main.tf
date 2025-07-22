provider "aws" {
  region = "eu-central-1"

  default_tags {
    tags = {
      Project     = "live-scores"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

resource "aws_acm_certificate" "django_alb" {
  domain_name       = "livescores-api.${var.route53_hosted_zone_name}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# When a SSL certificate is requested from AWS Certificate Manager (ACM), 
# AWS asks you to create special DNS records to prove you own the domain.
resource "aws_route53_record" "domain_validation_for_django_alb" {
  for_each = {
    for dvo in aws_acm_certificate.django_alb.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = var.route53_hosted_zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "django_alb" {
  certificate_arn         = aws_acm_certificate.django_alb.arn
  validation_record_fqdns = [for record in aws_route53_record.domain_validation_for_django_alb : record.fqdn]
}

resource "aws_route53_record" "django_alb" {
  zone_id = var.route53_hosted_zone_id             
  name    = "livescores-api.${var.route53_hosted_zone_name}"    
  type    = "A"

  alias {
    name                   = module.alb.dns_name   # ALB DNS name output from the ALB module
    zone_id                = module.alb.zone_id    # ALB zone ID output from the ALB module
    evaluate_target_health = true
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"

  name = "live-scores-backend-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
  private_subnets = ["10.0.1.0/24",   "10.0.2.0/24",   "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_dns_hostnames    = true
}

module "aurora_postgres" {
  source  = "terraform-aws-modules/rds-aurora/aws"

  name                = "my-aurora-postgres"
  engine              = "aurora-postgresql"
  engine_version      = "16.6"
  instance_class      = "db.t4g.medium"

  vpc_id              = module.vpc.vpc_id
  subnets             = module.vpc.private_subnets

  # Aurora needs a subnet group in *at least 2 AZs*
  create_db_subnet_group = true

  # Database configuration
  master_username = var.aurora_postgres_db_master_username
  master_password = var.aurora_postgres_db_master_password

  # Security group to allow access from EC2/Django
  create_security_group = true
  security_group_rules = {
    access_from_django_app = {
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      description = "Allow PostgreSQL access from django app"
      source_security_group_id = aws_security_group.ec2_sg.id
    }
  }

  apply_immediately = false
}

module "elasticache" {
  source = "terraform-aws-modules/elasticache/aws"

  cluster_id               = "redis-oss"
  create_cluster           = true
  create_replication_group = false
  num_cache_nodes          = 1

  engine_version = "7.1"
  node_type      = "cache.t4g.micro"

  maintenance_window = "sun:04:00-sun:08:00"
  apply_immediately  = true

  # Security group
  vpc_id = module.vpc.vpc_id
  security_group_rules = {
    ingress_vpc = {
      # Default type is `ingress`
      # Default port is based on the default engine port
      description = "VPC traffic"
      cidr_ipv4   = module.vpc.vpc_cidr_block
    }
  }

  # Subnet Group
  subnet_ids = [module.vpc.private_subnets[0]]

  # Parameter Group
  create_parameter_group = true
  parameter_group_family = "redis7"
  parameters = [
    {
      name  = "latency-tracking"
      value = "yes"
    }
  ]
}

resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Allow HTTP/HTTPS from the internet"
  vpc_id      = module.vpc.vpc_id

  ingress {
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
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"

  name               = "django-alb"
  load_balancer_type = "application"
  vpc_id             = module.vpc.vpc_id
  subnets            = module.vpc.public_subnets

  security_groups = [aws_security_group.alb_sg.id]
  
  target_groups = [
    {
      name_prefix      = "django"
      backend_protocol = "HTTP"
      backend_port     = 80
      target_type      = "instance"
      health_check = {
        path = "/"
      }
      targets = [
        {
          target_id = module.ec2_instance.id
          port      = 80
        }
      ]
    }
  ]

  listeners = {
    http-to-https-redirect = {
      port     = 80
      protocol = "HTTP"
      default_action = {          # ✅ Correct: redirect is inside default_action
        type     = "redirect"
        redirect = {
          port        = "443"
          protocol    = "HTTPS"
          status_code = "HTTP_301"
        }
      }
    }
    https = {
      port            = 443
      protocol        = "HTTPS"
      certificate_arn = aws_acm_certificate.django_alb.arn
      default_action = {
        type   = "forward"
        forward = {
          target_group_key = "django"
        }
      }
    }
  }
}

resource "aws_security_group" "ec2_sg" {
  name        = "ec2-instance-sg"
  description = "Allow inbound traffic for app"
  vpc_id      = module.vpc.vpc_id

  # Allow SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${var.my_ip_address}/32"]
  }

  # Allow HTTP from ALB only
  ingress {
    description      = "HTTP from ALB"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    security_groups  = [aws_security_group.alb_sg.id]
  }

  # Egress — allow all outbound (typical default)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

module "ec2_instance" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  name = "django-instance"

  instance_type = var.instance_type
  key_name      = "django-instance-keypair"
  monitoring    = true
  subnet_id     = module.vpc.public_subnets[0]

  associate_public_ip_address = true
}
