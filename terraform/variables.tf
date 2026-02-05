variable "github_repo_url" {
  description = "URL do Repositório GitHub para o ArgoCD monitorar"
  type        = string
  # SUBSTITUA PELA URL DO SEU REPOSITÓRIO (ex: https://github.com/seu-user/health-flow)
  default = "https://github.com/marcospls21/bootcamp-health-flow"
}
