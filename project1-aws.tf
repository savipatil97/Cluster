# Configure the EKS provider
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "4.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region = "us-east-1"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "eks-vpc"
  cidr = "10.0.0.0/16"

  enable_nat_gateway = true
  enable_vpn_gateway = true

  tags = {
    Terraform   = "true"
    Environment = var.environment
  }
}

resource "aws_internet_gateway" "eks-gw" {
  vpc_id = module.vpc.vpc_id
  tags = {
    Environment = var.environment
  }
  depends_on = [
    module.vpc
  ]
}

resource "aws_subnet" "eks-public" {
  cidr_block              = "10.0.16.0/24"
  vpc_id                  = module.vpc.vpc_id
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1b"

  tags = {
    Name = "public"
  }
  depends_on = [
    module.vpc
  ]
}

resource "aws_subnet" "private" {
  cidr_block              = "10.0.64.0/24"
  vpc_id                  = module.vpc.vpc_id
  map_public_ip_on_launch = false
  availability_zone       = "us-east-1f"

  tags = {
    Name = "private"
  }
  depends_on = [
    module.vpc
  ]
}

resource "aws_eip" "eks-eip" {
  vpc = true

  depends_on = [aws_internet_gateway.eks-gw]
}

resource "aws_nat_gateway" "eks-nat" {
  allocation_id = aws_eip.eks-eip.id
  subnet_id     = aws_subnet.eks-public.id

  tags = {
    Environment = var.environment
  }
  depends_on = [aws_internet_gateway.eks-gw]
}

resource "aws_route_table" "eks-route" {
  vpc_id = module.vpc.vpc_id

  route = []

  tags = {
    Environment = var.environment
  }
}
resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.eks-public.id
  route_table_id = aws_route_table.eks-route.id
}

resource "aws_route" "eks-route" {
  route_table_id         = aws_route_table.eks-route.id
  gateway_id             = aws_internet_gateway.eks-gw.id
  destination_cidr_block = "0.0.0.0/0"
  depends_on = [
    aws_route_table.eks-route
  ]
}

# EKS Cluster IAM Role
resource "aws_iam_role" "role" {
  name = "eks-Cluster-Role"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

data "aws_iam_policy_document" "policy" {
  statement {
    effect    = "Allow"
    actions   = ["ec2:Describe*"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "policy" {
  name        = "test-policy"
  description = "A test policy"
  policy      = data.aws_iam_policy_document.policy.json
}

resource "aws_iam_role_policy_attachment" "eksAmazonEKSClusterPolicy" {
  role       = aws_iam_role.role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eksAmazonEKSVPCResourceController" {
  role       = aws_iam_role.role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

resource "aws_eks_cluster" "eks-clus" {
  name     = "eks_clus"
  role_arn = aws_iam_role.role.arn

  vpc_config {
    subnet_ids = [aws_subnet.eks-public.id, aws_subnet.private.id]
  }

  # Ensure that IAM Role permissions are created before and deleted after EKS Cluster handling.
  # Otherwise, EKS will not be able to properly delete EKS managed EC2 infrastructure such as Security Groups.
  depends_on = [
    aws_iam_role_policy_attachment.eksAmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.eksAmazonEKSVPCResourceController,
  ]
}

module "web_server_sg" {
  source = "terraform-aws-modules/security-group/aws//modules/http-80"

  name        = "web-server"
  description = "Security group for web-server with HTTP ports open within VPC"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = ["10.10.0.0/24"]
}

