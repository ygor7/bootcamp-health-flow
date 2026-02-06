data "aws_availability_zones" "available" {}
data "aws_caller_identity" "current" {}

# --- DEFINIÇÃO DAS ROLES ---
locals {
  # ARNs do Academy
  cluster_role_arn = "arn:aws:iam::092257582592:role/c196815a5042644l13705335t1w092257-LabEksClusterRole-NAOZccg6RpK2"
  node_role_arn    = "arn:aws:iam::092257582592:role/c196815a5042644l13705335t1w092257582-LabEksNodeRole-8H5Iu2WsUOUe"
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

# --- SEGURANÇA: SG PARA O BANCO DE DADOS ---
resource "aws_security_group" "db_sg" {
  name        = "health-flow-db-sg"
  description = "Permite acesso ao RDS"
  vpc_id      = module.vpc.vpc_id # Garante a VPC certa

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- EKS CLUSTER ---
resource "aws_eks_cluster" "this" {
  name     = "health-flow-cluster"
  role_arn = local.cluster_role_arn
  version  = "1.32"

  vpc_config {
    subnet_ids             = module.vpc.private_subnets
    endpoint_public_access = true
  }

  tags = { Project = "Health-Flow" }
}

# --- EKS NODE GROUP ---
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

# --- RDS POSTGRES ---
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

  family = "postgres14"

  manage_master_user_password = false
  password                    = "Password123!"

  # Força a criação do grupo de subnets para evitar usar o default da VPC errada
  create_db_subnet_group = true
  subnet_ids             = module.vpc.public_subnets
  vpc_security_group_ids = [aws_security_group.db_sg.id]

  publicly_accessible = true
  skip_final_snapshot = true
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

# --- HELM: Datadog (Versão Corrigida) ---
resource "helm_release" "datadog" {
  name             = "datadog"
  repository       = "https://helm.datadoghq.com"
  chart            = "datadog"
  namespace        = "datadog"
  create_namespace = true
  version          = "3.48.0"

  depends_on = [aws_eks_node_group.this]

  wait    = true
  atomic  = true
  cleanup_on_fail = true
  timeout = 1800  # 30 minutos (EKS + nodes + pull de imagens pode demorar em academy)

  set_sensitive {
    name  = "datadog.apiKey"
    value = var.datadog_api_key
  }

  set { name = "datadog.site" value = "datadoghq.com" }
  set { name = "datadog.logs.enabled" value = "true" }
  set { name = "datadog.logs.containerCollectAll" value = "true" }
  set { name = "clusterAgent.enabled" value = "true" }
  set { name = "clusterAgent.metricsProvider.enabled" value = "true" }
  set { name = "kubeStateMetricsCore.enabled" value = "true" }
}


# --- DEPLOY APPS (Com criação de Namespace) ---
resource "null_resource" "deploy_apps" {
  depends_on = [helm_release.argocd]

  provisioner "local-exec" {
    # Adicionado 'kubectl create ns' para corrigir o erro 'namespace not found'
    command = <<EOT
      aws eks update-kubeconfig --region us-east-1 --name ${aws_eks_cluster.this.name}
      kubectl create namespace health-core || true
      kubectl create namespace health-video || true
      kubectl apply -f ../k8s/core/
      kubectl apply -f ../k8s/video/
    EOT
  }
}
