# Employee Task Tracker — Infrastructure Repository

Terraform code for the AWS infrastructure this app runs on: VPC, EKS, RDS, ECR, DNS/TLS, and a Jenkins server. One `terraform apply` builds all of it. What actually runs on the cluster is deployed by ArgoCD - see [employee-task-gitops](https://github.com/rashmiranjan7/employee-task-gitops).

Part of a 3-repo project. The other two: [employee-task-app](https://github.com/rashmiranjan7/employee-task-app) (application source + CI/CD, start here for full setup steps) and [employee-task-gitops](https://github.com/rashmiranjan7/employee-task-gitops) (the ArgoCD Application that deploys it).

This project only runs one environment (dev) — this is a portfolio/learning project, not a real company setup, so there's no separate prod environment to keep in sync.

## Folder structure

```
terraform/
  main.tf, variables.tf, outputs.tf   everything, one apply
  backend.hcl                         S3 backend config
  terraform.tfvars.example            copy to terraform.tfvars and fill in
  modules/
    vpc/              network: public/private/database subnets
    eks/               the Kubernetes cluster + IRSA role for the ALB controller
    rds/               the MySQL database
    ecr/               2 container repos (backend, frontend)
    acm/               HTTPS certificate for the one app hostname
    route53/            looks up the existing hosted zone (doesn't create one)
    jenkins-server/     one EC2 instance; user-data.sh installs Jenkins on boot

k8s/argocd/
  ingress.yaml.tpl   template for ArgoCD's UI Ingress

scripts/
  bootstrap-backend.sh       one-time: creates the S3 bucket + DynamoDB table for state
  sync-config.sh              copies terraform output (registry, cert ARN) into
                                employee-task-app's Helm chart values.yaml
  install-cluster-addons.sh   installs the AWS Load Balancer Controller + ArgoCD
  install-monitoring.sh       (optional) installs Prometheus/Grafana in-cluster
  update-dns.sh                points one hostname at one ALB
```

## Technology stack

Terraform · AWS (VPC, EKS, RDS, ECR, IAM, Route53, ACM, EC2)

## Setup instructions

```bash
cd terraform
../scripts/bootstrap-backend.sh us-east-1     # one-time: creates the S3 + DynamoDB backend

cp terraform.tfvars.example terraform.tfvars   # fill in your own values
terraform init -backend-config=backend.hcl
terraform apply -var-file=terraform.tfvars
```

That one apply creates the VPC, EKS cluster, RDS database, ECR repos, ACM cert, GitHub OIDC role, and the Jenkins server (Jenkins installs itself automatically on boot - no separate step needed).

Full step-by-step order across all 3 repos: `employee-task-app`'s [SETUP.md](https://github.com/rashmiranjan7/employee-task-app/blob/main/SETUP.md).

## Deployment instructions

"Deploying" this repo means applying a Terraform change:

```bash
cd terraform
terraform plan -var-file=terraform.tfvars     # always review before applying
terraform apply -var-file=terraform.tfvars
```

If you change `terraform/modules/jenkins-server/user-data.sh`, that only runs again on a fresh EC2 boot — `terraform apply` won't re-run it on the existing instance. Easiest fix: `terraform taint module.jenkins_server.aws_instance.jenkins` then apply again.

## Rollback procedure

`git revert` the `.tf`/`.tfvars` change in question, then `terraform apply` again. Always run `terraform plan` before every apply so you see exactly what will change first.

## Troubleshooting guide

| Symptom | Likely cause |
|---|---|
| `Error: Error acquiring the state lock` | A previous `apply`/`plan` didn't exit cleanly — `terraform force-unlock <lock-id>` after confirming no one else is applying |
| `data.aws_route53_zone.this: no matching Route53Zone found` | The domain's hosted zone doesn't exist in this account yet — this repo only looks it up, never creates it |
| ACM stuck `PENDING_VALIDATION` past when `terraform apply` finishes | Almost always DNS delegation, not a Terraform bug — `dig NS <domain> +short` should return AWS nameservers |
| Jenkins UI not reachable | Wait 2-3 minutes after `terraform apply` for user-data.sh to finish, then check `jenkins_admin_cidr` matches your current IP |
| Jenkins job fails with "command not found" | SSH in and check `/var/log/cloud-init-output.log` — user-data.sh may still be running or failed partway |
| ALB never gets created / Ingress has no `ADDRESS` | Almost always IRSA — see `employee-task-app`'s TROUBLESHOOTING.md |

Full troubleshooting guide (covers all 3 repos): `employee-task-app`'s [TROUBLESHOOTING.md](https://github.com/rashmiranjan7/employee-task-app/blob/main/TROUBLESHOOTING.md).

## Why Terraform installs Jenkins with user_data instead of a separate tool

Terraform creates the EC2 instance AND passes it a boot script (`user-data.sh`) that installs Docker, Jenkins, kubectl, Helm, Trivy, and Node. One `terraform apply`, no second tool or second step to remember to run.

## Why the AWS Load Balancer Controller uses IRSA, not the node's IAM role

The controller's IAM role and policy (`terraform/modules/eks/irsa.tf`) are fully Terraform-managed. `scripts/install-cluster-addons.sh` annotates the controller's ServiceAccount with that role's ARN and checks the annotation actually landed, since a correct IRSA role has zero effect until that annotation exists.

## Screenshots

_Add a `terraform plan` output, the AWS Console showing the EKS cluster and RDS instance, and the Jenkins UI here once deployed._
