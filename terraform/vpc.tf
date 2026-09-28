data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs                  = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets       = [cidrsubnet(var.vpc_cidr, 4, 0), cidrsubnet(var.vpc_cidr, 4, 1)]
  private_subnets      = [cidrsubnet(var.vpc_cidr, 4, 8), cidrsubnet(var.vpc_cidr, 4, 9)]
  public_data_subnets  = [cidrsubnet(var.vpc_cidr, 4, 4), cidrsubnet(var.vpc_cidr, 4, 5)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.project}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false
  enable_dns_hostnames   = true
  enable_dns_support     = true

  # Tag subnets so EKS and the AWS Load Balancer Controller can discover them.
  # Public subnets host the internet-facing ALB; private subnets host Fargate pods.
  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }
}

################################################################################
# Additional "public" subnets for the data plane.
#
# These are created outside the VPC module so we can attach them to the private
# route table (NAT egress only). They are named "...-public-..." and live in
# the same address space the operator marked for public workloads. EKS Fargate
# profiles in eks.tf reference them.
################################################################################
resource "aws_subnet" "public_data" {
  count             = length(local.public_data_subnets)
  vpc_id            = module.vpc.vpc_id
  cidr_block        = local.public_data_subnets[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name                                        = "${var.project}-vpc-public-data-${local.azs[count.index]}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_route_table_association" "public_data" {
  count          = length(aws_subnet.public_data)
  subnet_id      = aws_subnet.public_data[count.index].id
  route_table_id = element(module.vpc.private_route_table_ids, count.index)
}
