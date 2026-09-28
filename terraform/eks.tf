module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  # Known debt (see SOLUTION.md): public endpoint is open to 0.0.0.0/0.
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  enable_irsa = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Fargate-only cluster: every pod needs a matching profile, otherwise it stays Pending.
  fargate_profiles = {
    # CoreDNS and the AWS Load Balancer Controller both live in kube-system.
    kube_system = {
      name = "kube-system"
      selectors = [
        { namespace = "kube-system" }
      ]
      subnet_ids = module.vpc.private_subnets
    }

    # Workload namespace must match k8s/namespace.yaml.
    apps = {
      name = "apps"
      selectors = [
        { namespace = var.app_namespace }
      ]
      subnet_ids = module.vpc.private_subnets
    }
  }

  cluster_addons = {
    coredns = {
      most_recent = true
      configuration_values = jsonencode({
        computeType = "Fargate"
        resources = {
          limits   = { cpu = "0.25", memory = "256M" }
          requests = { cpu = "0.25", memory = "256M" }
        }
      })
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }

  # Cluster-admin for the identity running terraform apply (the assumed role).
  # Production: dedicated access entries with least privilege and SSO.
  enable_cluster_creator_admin_permissions = true

  tags = {
    Project = var.project
  }
}
