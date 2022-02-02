terraform {
  required_version = ">= 1.0.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.73.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.7.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.4.1"
    }
    grafana = {
      source  = "grafana/grafana"
      version = ">= 1.13.3"
    }
  }

  backend "local" {
    path = "local_tf_state/terraform-main.tfstate"
  }
}

locals {
  tenant      = "aws001"        # AWS account name or unique id for tenant
  environment = "preprod"       # Environment area eg., preprod or prod
  zone        = "observability" # Environment within one sub_tenant or business unit

  kubernetes_version = "1.21"

  vpc_cidr     = "10.0.0.0/16"
  vpc_name     = join("-", [local.tenant, local.environment, local.zone, "vpc"])
  cluster_name = join("-", [local.tenant, local.environment, local.zone, "eks"])

  terraform_version = "Terraform v1.1.4"

  # Sample workload managed by ArgoCD. For generating metrics and logs
  workload_application = {
    path               = "envs/dev"
    repo_url           = "https://github.com/aws-samples/ssp-eks-workloads.git"
    add_on_application = false
  }
}

module "aws_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "v3.11.3"

  name = local.vpc_name
  cidr = local.vpc_cidr
  azs  = data.aws_availability_zones.available.names

  public_subnets  = [for k, v in slice(data.aws_availability_zones.available.names, 0, 3) : cidrsubnet(local.vpc_cidr, 8, k)]
  private_subnets = [for k, v in slice(data.aws_availability_zones.available.names, 0, 3) : cidrsubnet(local.vpc_cidr, 8, k + 10)]

  enable_nat_gateway   = true
  create_igw           = true
  enable_dns_hostnames = true
  single_nat_gateway   = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }
}

module "aws-eks-accelerator-for-terraform" {
  source = "../.."

  tenant            = local.tenant
  environment       = local.environment
  zone              = local.zone
  terraform_version = local.terraform_version

  # EKS Cluster VPC and Subnet mandatory config
  vpc_id             = module.aws_vpc.vpc_id
  private_subnet_ids = module.aws_vpc.private_subnets

  # EKS Control Plane Variables
  create_eks         = true
  kubernetes_version = local.kubernetes_version

  managed_node_groups = {
    mg_4 = {
      node_group_name = "managed-ondemand"
      instance_types  = ["m5.xlarge"]
      min_size        = 3
      subnet_ids      = module.aws_vpc.private_subnets
    }
  }

  # Provisions a new Amazon Managed Service for Prometheus instance
  enable_amazon_prometheus = true
}

module "kubernetes-addons" {
  source         = "../../modules/kubernetes-addons"
  eks_cluster_id = module.aws-eks-accelerator-for-terraform.eks_cluster_id

  #K8s Add-ons
  enable_metrics_server     = true
  enable_cluster_autoscaler = true
  enable_argocd             = true
  argocd_applications = {
    workloads = local.workload_application
  }

  # Fluentbit
  enable_aws_for_fluentbit        = true
  aws_for_fluentbit_irsa_policies = [aws_iam_policy.fluentbit-opensearch-access.arn]
  aws_for_fluentbit_helm_config = {
    values = [templatefile("${path.module}/helm_values/aws-for-fluentbit-values.yaml", {
      aws_region = data.aws_region.current.name,
      host       = aws_elasticsearch_domain.opensearch.endpoint
    })]
  }

  # Prometheus and Amazon Managed Prometheus integration
  enable_prometheus                    = true
  enable_amazon_prometheus             = true
  amazon_prometheus_workspace_endpoint = module.aws-eks-accelerator-for-terraform.amazon_prometheus_workspace_endpoint
}

resource "grafana_data_source" "prometheus" {
  type       = "prometheus"
  name       = "amp"
  is_default = true
  url        = module.aws-eks-accelerator-for-terraform.amazon_prometheus_workspace_endpoint
  json_data {
    http_method     = "POST"
    sigv4_auth      = true
    sigv4_auth_type = "workspace-iam-role"
    sigv4_region    = data.aws_region.current.name
  }
}

resource "aws_elasticsearch_domain" "opensearch" {
  domain_name           = "opensearch"
  elasticsearch_version = "OpenSearch_1.1"

  cluster_config {
    instance_type          = "m4.large.elasticsearch"
    instance_count         = 3
    zone_awareness_enabled = true
    zone_awareness_config {
      availability_zone_count = 3
    }
  }
  node_to_node_encryption {
    enabled = true
  }
  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }
  encrypt_at_rest {
    enabled = true
  }
  ebs_options {
    ebs_enabled = true
    volume_size = var.ebs_volume_size
  }

  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = true
    master_user_options {
      master_user_name     = var.opensearch_dashboard_user
      master_user_password = var.opensearch_dashboard_pw
    }
  }
}

resource "aws_iam_policy" "fluentbit-opensearch-access" {
  name        = "fluentbit-opensearch-access"
  description = "IAM policy to allow Fluentbit access to OpenSearch"
  policy      = data.aws_iam_policy_document.fluentbit-opensearch-access.json
}

resource "aws_elasticsearch_domain_policy" "opensearch_access_policy" {
  domain_name     = aws_elasticsearch_domain.opensearch.domain_name
  access_policies = data.aws_iam_policy_document.opensearch_access_policy.json
}