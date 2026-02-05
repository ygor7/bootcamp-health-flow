data "aws_availability_zones" "available" {}
data "aws_caller_identity" "current" {}

# --- DEFINIÇÃO DAS ROLES ---
locals {
  # Insira os ARNs que funcionam no seu laboratório
  cluster_role_arn = "arn:aws:iam::074442581040:role/c196815a5042644l13691097t1w074442-LabEksClusterRole-z4U15qTttNJF"
  node_role_arn    = "arn:aws:iam::074442581040:role/c196815a5042644l13691097t1w074442581-LabEksNodeRole-gSRwpwgLZvgg"
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

# --- EKS CLUSTER (NATIVO) ---
resource "aws_eks_cluster" "this" {
  name     = "health-flow-cluster"
  role_arn = local.cluster_role_arn
  version  = "1.28"

  vpc_config {
    subnet_ids             = module.vpc.private_subnets
    endpoint_public_access = true
  }

  tags = { Project = "Health-Flow" }
}

# --- EKS NODE GROUP (NATIVO) ---
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "health-flow-workers"
  node_role_arn   = local.node_role_arn
  subnet_ids      = module.vpc.private_subnets

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }

  instance_types = ["t3.medium"]
  capacity_type  = "ON_DEMAND"

  depends_on = [aws_eks_cluster.this]

  tags = { Project = "Health-Flow" }
}

# --- OIDC PROVIDER ---
data "tls_certificate" "this" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.this.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

# --- RDS POSTGRES (CORRIGIDO) ---
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

  # --- CORREÇÃO DO ERRO 'FAMILY' ---
  family = "postgres14" # Obrigatório na versão 6+

  manage_master_user_password = false
  password                    = "Password123!"

  vpc_security_group_ids = [module.vpc.default_security_group_id]
  subnet_ids             = module.vpc.public_subnets
  publicly_accessible    = true
  skip_final_snapshot    = true
}

# --- HELM: Ingress ---
resource "helm_release" "nginx_ingress" {
  name             = "nginx-ingress"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "nginx-system"
  create_namespace = true
  version          = "4.7.1"

  depends_on = [aws_eks_node_group.this]

  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }
}

# --- HELM: ArgoCD ---
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "5.46.7"

  depends_on = [aws_eks_node_group.this]

  set {
    name  = "server.service.type"
    value = "LoadBalancer"
  }
}

# --- DEPLOY DAS APPS (VIA SCRIPT) ---
# Substitui o kubernetes_manifest para evitar erros de conexão no plano
resource "null_resource" "deploy_apps" {
  depends_on = [helm_release.argocd]

  provisioner "local-exec" {
    # Atualiza o kubeconfig e aplica os arquivos YAML
    command = <<EOT
      aws eks update-kubeconfig --region us-east-1 --name ${aws_eks_cluster.this.name}
      kubectl apply -f ../k8s/core/
      kubectl apply -f ../k8s/video/
    EOT
  }
}
