# Employee Task Tracker — Infrastructure Repository

This repo has the Terraform code. It builds all the AWS infrastructure the app runs on. That means the network, the Kubernetes cluster, the database, the container registry, DNS, HTTPS, and a Jenkins server. One command (`terraform apply`) builds all of it.

This repo does not deploy the app. It only builds the infrastructure. The app itself is deployed by ArgoCD. That part lives in [employee-task-gitops](https://github.com/rashmiranjanDevOps/employee-task-gitops).

## Part of a 3-repo project

| Repo | What it does |
|---|---|
| [employee-task-app](https://github.com/rashmiranjan7/employee-task-app.git) | The app code, the Helm chart, and CI/CD. Start here for setup steps. |
| **employee-task-infra** (this one) | Terraform. Everything the app runs on. |
| [employee-task-gitops](https://github.com/rashmiranjan7/employee-task-gitops.git) | The ArgoCD file that deploys the app. |

This project has only one environment: dev. There is no separate prod. This is a learning project, not a real company setup.

## Folder structure

```
terraform/
  main.tf, variables.tf, outputs.tf   Everything, wired together, one apply
  backend.hcl                         Where Terraform stores its state (S3)
  terraform.tfvars.example            Copy this to terraform.tfvars and fill in your values
  modules/
    vpc/              The network: public, private, and database subnets
    eks/              The Kubernetes cluster, plus the role the load balancer controller uses
    rds/               The MySQL database
    ecr/                Two container repos, one for the backend and one for the frontend
    acm/                The HTTPS certificate for the app's domain
    route53/            Finds the domain's existing DNS zone (does not create one)
    jenkins-server/     One EC2 server. It installs Jenkins on itself when it boots.

k8s/argocd/
  ingress.yaml.tpl   Template for ArgoCD's own web address

scripts/
  bootstrap-backend.sh       Run once: creates the S3 bucket and DynamoDB table Terraform needs
  sync-config.sh              Copies values from Terraform into the app repo's Helm chart
  install-cluster-addons.sh   Installs the load balancer controller and ArgoCD
  install-monitoring.sh       Optional: installs Prometheus and Grafana in the cluster
  update-dns.sh                Points the app's domain at the load balancer
```

## Tech stack

Terraform, AWS (VPC, EKS, RDS, ECR, IAM, Route53, ACM, EC2)

## What this builds

One `terraform apply` creates:
- A VPC with public, private, and database subnets, across 2 zones
- An EKS (Kubernetes) cluster with one small group of worker nodes
- An RDS MySQL database. Only the EKS nodes can reach it.
- Two ECR repos, for the backend and frontend images
- A Route53 lookup and an ACM certificate, for HTTPS
- An IAM role that GitHub Actions can use. No AWS keys are stored in GitHub.
- An EC2 server that installs Jenkins on itself automatically

## Setup

```bash
cd terraform
../scripts/bootstrap-backend.sh us-east-1     # run once: creates the S3 + DynamoDB backend

cp terraform.tfvars.example terraform.tfvars   # fill in your own values
terraform init -backend-config=backend.hcl
terraform apply -var-file=terraform.tfvars
```

This is the short version. For the full step-by-step process, with a check after every step, see [SETUP-FULL.md](./SETUP-FULL.md).

## Before you run any script: set your real domain

Two scripts have a placeholder domain in them. Terraform does not fill this in for you. You have to edit it by hand.

- `scripts/install-cluster-addons.sh`
- `scripts/sync-config.sh`

Both files have this line near the top:

```bash
APP_DOMAIN="yourdomain.com"   # same value as domain_name in terraform.tfvars
```

Open both files and change it to your real domain:

```bash
APP_DOMAIN="rashmidevops.xyz"
```

If you skip this step, two things go wrong:
- `install-cluster-addons.sh` will try to open ArgoCD at `argocd.yourdomain.com`, not your real domain.
- `sync-config.sh` will write the wrong `host` value into the Helm chart.

`update-dns.sh` does not need this fix. Its domain is already set correctly.

## Making a change

To "deploy" this repo, you apply a Terraform change:

```bash
terraform plan -var-file=terraform.tfvars     # always check what will change first
terraform apply -var-file=terraform.tfvars
```

One thing to know: if you edit `terraform/modules/jenkins-server/user-data.sh`, it only runs again when the EC2 server boots fresh. A normal `terraform apply` will not re-run it on a server that's already running. To force it to run again:

```bash
terraform taint module.jenkins_server.aws_instance.jenkins
terraform apply -var-file=terraform.tfvars
```

## Rolling back a bad change

Use `git revert` on the `.tf` file you changed, then run `terraform apply` again. Always run `terraform plan` first, so you know exactly what will change before it happens.

## Full runbooks

The steps above are the short version. For the complete process, with a check after every step, see:

- [SETUP.md](./SETUP.md) — the full path from nothing to a live app with monitoring
- [DESTROY.md](./DESTROY.md) — the full teardown, in the order that avoids leftover AWS load balancers and surprise charges

## Cost and why I made these choices

This is a small personal project. I made a few choices to keep the cost low, instead of copying a full production setup:

- **One shared NAT Gateway**, instead of one per zone. This saves about $32/month. The trade-off: if that one zone has an outage, both private subnets lose internet access at the same time. A real company would use one NAT per zone. For a learning project, one shared NAT is the normal choice.
- **No extra encryption key (KMS).** RDS and EKS already encrypt data using AWS's own default key. Adding a second key would be one more thing to manage, for no real benefit here.
- **RDS backups kept for only 1 day**, and no final snapshot on delete. This is a dev database. I rebuild it often. I don't need long backup history for it.
- **One small worker node** (t3.medium), instead of an auto-scaling group of bigger nodes. Enough to run the app. Not built for real user traffic.

Rough cost: **$60–90 per month** while it's running. I run `terraform destroy` (see [DESTROY.md](./DESTROY.md)) between work sessions, so I don't pay for it while I'm not using it.

## Troubleshooting

| Problem | Likely cause |
|---|---|
| `Error acquiring the state lock` | A previous apply or plan didn't finish cleanly. Run `terraform force-unlock <lock-id>`, but only after checking no one else is applying. |
| `no matching Route53Zone found` | The domain's DNS zone doesn't exist in this AWS account yet. This repo only looks it up — it never creates one. |
| ACM certificate stuck on `PENDING_VALIDATION` | Almost always a DNS problem, not a Terraform bug. Run `dig NS <domain> +short` and check it returns AWS's nameservers. |
| ArgoCD or the app shows up at the wrong domain | `APP_DOMAIN` was never changed in `install-cluster-addons.sh` or `sync-config.sh`. See the section above. |
| Jenkins UI not reachable | Wait 2–3 minutes after `terraform apply` for the boot script to finish. Then check `jenkins_admin_cidr` matches your current IP. |
| Jenkins job fails with "command not found" | SSH into the server and check `/var/log/cloud-init-output.log`. The boot script may still be running, or it may have failed partway. |
| ALB never gets created, or the Ingress has no address | Almost always an IAM role problem (IRSA). See `employee-task-app`'s TROUBLESHOOTING.md. |
| Teardown gets stuck on a VPC or subnet | A leftover load balancer or target group is still attached. See [DESTROY.md](./DESTROY.md) — it has checks built in for exactly this. |

Full troubleshooting guide across all 3 repos: `employee-task-app`'s [TROUBLESHOOTING.md](https://github.com/rashmiranjan7/employee-task-app/blob/main/TROUBLESHOOTING.md).

## Why Terraform installs Jenkins by itself

Terraform creates the EC2 server and gives it a boot script (`user-data.sh`). That script installs Docker, Jenkins, kubectl, Helm, Trivy, and Node automatically. So one `terraform apply` is the whole setup. There's no second step to remember.

## Why the Load Balancer Controller uses its own role, not the node's role

This is called IRSA. It means only the load balancer controller's own Kubernetes account gets AWS permissions — not the whole node. The role is fully set up in `terraform/modules/eks/irsa.tf`. The script `install-cluster-addons.sh` checks that this role is actually attached before moving on, because the role does nothing until it's attached.
