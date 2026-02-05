data "aws_availability_zones" "available" {}
data "aws_caller_identity" "current" {}

# --- DEFINIÇÃO DAS ROLES (Estratégia de Backup) ---
locals {
  # 1. Role Padrão do Academy
  lab_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/LabRole"

  # 2. Roles Específicas (Backup de Segurança)
  specific_cluster_role = "arn:aws:iam::074442581040:role/c196815a5042644l13691097t1w074442-LabEksClusterRole-z4U15qTttNJF"
  specific_node_role    = "arn:aws:iam::074442581040:role/c196815a5042644l13691097t1w074442581-LabEksNodeRole-gSRwpwgLZvgg"

  # Altere aqui caso precise trocar a Role
  used_cluster_role = local.lab_role_arn
  used_node_role    = local.lab_role_arn
}

# --- VPC ---
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = "health-flow-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  tags = { Project = "Health-Flow" }
}

# --- EKS Cluster (Versão 20 - Blindada para Academy) ---
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0" # ATUALIZAÇÃO IMPORTANTE

  cluster_name    = "health-flow-cluster"
  cluster_version = "1.28"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  # --- CORREÇÃO DO ERRO IAM:GetRole ---
  # Isso impede o módulo de tentar ler seu usuário 'voclabs'
  enable_cluster_creator_admin_permissions = false

  # Permite usar o aws-auth manual (ConfigMap) junto com a API nova
  authentication_mode = "API_AND_CONFIG_MAP"

  # Configurações do Academy (Roles existentes)
  create_iam_role = false
  iam_role_arn    = local.used_cluster_role

  create_kms_key = false
  enable_irsa    = false

  eks_managed_node_groups = {
    default = {
      min_size       = 1
      max_size       = 2
      desired_size   = 2
      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"

      create_iam_role = false
      iam_role_arn    = local.used_node_role
    }
  }
}

# --- AWS-AUTH (Acesso Manual Obrigatório) ---
# Como desligamos o admin automático acima, precisamos nos adicionar manualmente aqui
resource "kubernetes_config_map" "aws_auth" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  data = {
    mapRoles = yamlencode([
      # Permite os nós com LabRole
      {
        rolearn  = local.lab_role_arn
        username = "system:node:{{EC2PrivateDNSName}}"
        groups   = ["system:bootstrappers", "system:nodes"]
      },
      # Permite os nós com Role Específica (Backup)
      {
        rolearn  = local.specific_node_role
        username = "system:node:{{EC2PrivateDNSName}}"
        groups   = ["system:bootstrappers", "system:nodes"]
      },
      # Adiciona o usuário voclabs como Admin manualmente
      {
        rolearn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/voclabs"
        username = "voclabs"
        groups   = ["system:masters"]
      }
    ])
    mapUsers = yamlencode([])
  }

  depends_on = [module.eks]
}

# --- RDS Postgres ---
module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "6.1.1"

  identifier = "health-flow-db"

  engine            = "postgres"
  engine_version    = "14"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  db_name           = "healthflowdb"
  username          = "dbadmin"
  port              = 5432

  manage_master_user_password = false
  password                    = "Password123!"

  vpc_security_group_ids = [module.vpc.default_security_group_id]
  subnet_ids             = module.vpc.public_subnets
  publicly_accessible    = true
  skip_final_snapshot    = true
  family                 = "postgres14"
}

# --- Nginx Ingress ---
resource "helm_release" "nginx_ingress" {
  name             = "nginx-ingress"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "nginx-system"
  create_namespace = true
  version          = "4.7.1"
  depends_on       = [module.eks, kubernetes_config_map.aws_auth]

  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }
}

# --- ArgoCD ---
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "5.46.7"
  depends_on       = [module.eks, kubernetes_config_map.aws_auth]

  set {
    name  = "server.service.type"
    value = "LoadBalancer"
  }
}

# --- Argo Apps ---
resource "kubernetes_manifest" "app_core" {
  depends_on = [helm_release.argocd]
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "health-flow-core"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.github_repo_url
        targetRevision = "HEAD"
        path           = "k8s/core"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "health-core"
      }
      syncPolicy = {
        automated   = { prune = true, selfHeal = true }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  }
}

resource "kubernetes_manifest" "app_video" {
  depends_on = [helm_release.argocd]
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "health-flow-video"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.github_repo_url
        targetRevision = "HEAD"
        path           = "k8s/video"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "health-video"
      }
      syncPolicy = {
        automated   = { prune = true, selfHeal = true }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  }
}
