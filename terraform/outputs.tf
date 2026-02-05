output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = aws_eks_cluster.this.endpoint
}

output "db_endpoint" {
  description = "Endpoint for RDS instance"
  value       = module.db.db_instance_endpoint
}

output "configure_kubectl" {
  description = "Configure kubectl: run this command in your terminal"
  value       = "aws eks update-kubeconfig --region us-east-1 --name ${aws_eks_cluster.this.name}"
}

output "argocd_password_command" {
  description = "Command to get ArgoCD admin password"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}
