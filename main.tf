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

resource "aws_ecr_repository" "django" {
  name                 = "livescores/django-backend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_iam_role" "livescores_ec2_role" {
  name = "EC2-Role-Livescores"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_access_for_ec2" {
  role       = aws_iam_role.livescores_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "ssm_for_ec2" {
  role       = aws_iam_role.livescores_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM"
}

resource "aws_iam_instance_profile" "ecr_access_for_ec2" {
  name = "ecr-access-for-ec2-profile"
  role = aws_iam_role.livescores_ec2_role.name
}

resource "aws_iam_policy" "read_livescores_secrets" {
  name        = "SecretsManagerRead"
  description = "Allow EC2 to read livescores secrets from AWS Secrets Manager"
  policy      = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = aws_secretsmanager_secret.livescores_secrets.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_secretsmanager_read" {
  role       = aws_iam_role.livescores_ec2_role.name
  policy_arn = aws_iam_policy.read_livescores_secrets.arn
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.0.1"
  name = "live-scores-backend-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
  private_subnets = ["10.0.1.0/24",   "10.0.2.0/24",   "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_dns_hostnames    = true
  # depends_on = [module.ec2_instance] # This has been necessary to destroy all resources.
  # Otherwise the error message below was raised.
  # DependencyViolation: Network vpc-12345 has some mapped public address(es). 
  # Please unmap those public address(es) before detaching the gateway.
}

resource "aws_secretsmanager_secret" "livescores_secrets" {
  name = "django-livescores"
}

resource "aws_secretsmanager_secret_version" "livescores_secrets" {
  secret_id = aws_secretsmanager_secret.livescores_secrets.id
  secret_string = jsonencode({
    DB_HOST = module.aurora_postgres.cluster_endpoint
    DB_PORT = 5432
    DB_NAME = "livescores"
    DB_USERNAME = var.aurora_postgres_db_master_username
    DB_PASSWORD = var.aurora_postgres_db_master_password
    REDIS_HOST  = module.elasticache.cluster_cache_nodes[0].address
    REDIS_PORT  = module.elasticache.cluster_cache_nodes[0].port
  })
}

module "aurora_postgres" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "9.15.0"
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
  skip_final_snapshot = true # Must be true to destroy automatically
  apply_immediately = false
}

module "elasticache" {
  source = "terraform-aws-modules/elasticache/aws"
  version = "1.6.2"
  cluster_id               = "redis-oss"
  create_cluster           = true
  create_replication_group = false
  num_cache_nodes          = 1

  engine_version = "7.0"
  node_type      = "cache.t4g.micro"

  maintenance_window = "sun:04:00-sun:08:00"
  apply_immediately  = false

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
  version = "9.17.0"
  name                       = "django-alb"
  load_balancer_type         = "application"
  vpc_id                     = module.vpc.vpc_id
  subnets                    = module.vpc.public_subnets
  security_groups            = [aws_security_group.alb_sg.id]
  enable_deletion_protection = false # Must be true to destroy automatically

  target_groups = {
    django = {
      name_prefix  = "dj"
      protocol     = "HTTP"
      port         = 80
      target_type  = "instance"
      target_id    = module.ec2_instance.id
      health_check = {path = "/"}
    }
 }

  listeners = {
    http_to_https_redirect = {
      port     = 80
      protocol = "HTTP"
      redirect = {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
    https = {
      port            = 443
      protocol        = "HTTPS"
      certificate_arn = aws_acm_certificate.django_alb.arn
      forward = {
        target_group_key = "django"
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
  version = "6.0.2"
  name = "django-instance"

  instance_type = var.instance_type
  ami           = var.ami_id
  key_name      = "django-instance-keypair"
  monitoring    = true
  metadata_options = {
    http_put_response_hop_limit = 2
  }
  subnet_id     = module.vpc.public_subnets[0]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ecr_access_for_ec2.name
  # Install Docker on EC2
  user_data = <<-EOF
    #!/bin/bash
    echo ERTY > /home/ec2-user/erty.txt
    # Run these commands automatically
    sudo yum update -y
    sudo yum install -y docker
    sudo service docker start
    sudo usermod -aG docker ec2-user

    # Write setup.sh to /home/ec2-user/custom_scripts/deploy.sh, but do NOT run it
    mkdir -p /home/ec2-user/custom_scripts
    cat <<'SCRIPT' > /home/ec2-user/custom_scripts/deploy.sh
    ${file("${path.module}/custom_scripts/deploy.sh")}
    SCRIPT
    chmod +x /home/ec2-user/custom_scripts/deploy.sh
  EOF
}
