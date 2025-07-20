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

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"

  name = "live-scores-backend-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
  private_subnets = ["10.0.1.0/24",   "10.0.2.0/24",   "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_dns_hostnames    = true
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

  # Allow HTTP
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow HTTPS
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Egress — allow all outbound (typical default)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
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

module "ec2_instance" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  name = "django-instance"

  instance_type = var.instance_type
  key_name      = "django-instance-keypair"
  monitoring    = true
  subnet_id     = module.vpc.public_subnets[0]

  associate_public_ip_address = true
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