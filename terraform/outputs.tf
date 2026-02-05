output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}
output "db_endpoint" {
  value = module.db.db_instance_endpoint
}
output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region us-east-1 --name health-flow-cluster"
}
output "argocd_password" {
  value = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}
