# SETUP-FULL.md — Complete Runbook: Zero to Live App + Monitoring

Everything from a fresh `terraform apply` through Prometheus/Grafana,
written from what actually happened building this the first time —
every gate below exists because skipping that exact check cost real time
on a real run.

Total time: ~45-60 minutes. Most of it is waiting (EKS ~15-20 min,
cluster add-ons ~6-8 min), not typing.

---

## Step 0 — Confirm your shell actually works

Do this every time you sit down to work on this project, not just the
first time. A broken shell (wrong Linux user, no DNS resolver, no AWS
credentials) produces error messages that look exactly like an AWS
problem, and chasing the wrong one wastes far more time than this check
costs.

```bash
whoami
# expect: your normal Linux username

cat /etc/resolv.conf
# expect: a "nameserver" line. If "No such file or directory":
#   sudo bash -c 'echo "nameserver 8.8.8.8" > /etc/resolv.conf'

aws sts get-caller-identity
# expect: your AWS account JSON
```

---

## Step 1 — Terraform apply

```bash
cd employee-task-infra/terraform
cat terraform.tfvars   # sanity check: your domain, IP, key name, cluster_version all correct?

terraform init -backend-config=backend.hcl
terraform plan -var-file=terraform.tfvars     # review before applying, every time
terraform apply -var-file=terraform.tfvars
```
Type `yes`. ~15-20 minutes.

**Expect:** `Apply complete! Resources: 64 added, 0 changed, 0 destroyed.`

### GATE 1 — Verify the infra is actually healthy
```bash
aws eks update-kubeconfig --name employee-task-dev --region us-east-1
kubectl get nodes
kubectl get secret employee-task-secrets -n employee-task-dev -o jsonpath='{.data}' | jq 'keys'
```
**Expect:** 3 nodes `Ready`; 7 keys (`DB_HOST`, `DB_NAME`, `DB_PASSWORD`, `DB_PORT`,
`DB_USER`, `JWT_REFRESH_SECRET`, `JWT_SECRET`). Don't proceed until both
are true — everything downstream assumes a working cluster and a real
DB secret.

---

## Step 2 — Sync config into employee-task-app

```bash
cd ../employee-task-infra
./scripts/sync-config.sh ../employee-task-app
```
**Expect:** commits + pushes `values.yaml` with the real ECR registry, ACM
cert ARN, and hostname; prints 3 values to set in GitHub.

### GATE 2 — Confirm the values actually landed
```bash
grep -A1 "^image:" ../employee-task-app/helm/employee-task/values.yaml
grep "certificateArn\|host:" ../employee-task-app/helm/employee-task/values.yaml
```
**Expect:** none empty (`""`).

---

## Step 3 — Set GitHub Actions secrets/variables (one-time, skip if already set)

`https://github.com/<you>/employee-task-app/settings/secrets/actions`:
- Secret `AWS_ROLE_ARN` = the ARN `sync-config.sh` printed
- Secret `SLACK_WEBHOOK_URL` = optional

`https://github.com/<you>/employee-task-app/settings/variables/actions`:
- Variable `AWS_REGION` = `us-east-1`
- Variable `ECR_REGISTRY` = the registry `sync-config.sh` printed

---

## Step 4 — Install cluster add-ons (ALB Controller + ArgoCD)

```bash
./scripts/install-cluster-addons.sh
```
~6-8 minutes across 5 phases. Ends printing the ArgoCD admin password —
**save it now**, easy to lose track of later.

### GATE 3 — Confirm ArgoCD is actually reachable
```bash
curl -sk -o /dev/null -w "%{http_code}\n" https://argocd.rashmidevops.xyz
```
**Expect:** `200`. If `000`, wait 60 seconds and retry — DNS/ALB
propagation, not necessarily a real problem.

---

## Step 5 — Point ArgoCD at employee-task-gitops

```bash
cd ..
kubectl apply -f employee-task-gitops/apps/dev-application.yaml
kubectl -n argocd get applications
```
**Expect:** `Synced` / `Progressing` — Progressing is correct here, no
real image tag exists yet.

---

## Step 6 — Trigger the first CI/CD run

```bash
cd employee-task-app
git commit --allow-empty -m "trigger: first CI/CD run"
git push origin main
```
Watch: `https://github.com/<you>/employee-task-app/actions` — wait for
`test` → `secrets-scan` → `build-and-push` → `update-image-tag` all green.
`build-and-push` is the slowest job.

### GATE 4 — Confirm ArgoCD actually deployed it
```bash
sleep 30
kubectl -n argocd get applications
kubectl -n employee-task-dev get pods
```
**Expect:** `HEALTH STATUS: Healthy` (not `Progressing` anymore); both
pods `Running` `1/1`.

---

## Step 7 — Point DNS at the app's ALB

```bash
cd ../employee-task-infra
ALB_HOSTNAME=$(kubectl -n employee-task-dev get ingress employee-task-dev-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "ALB: $ALB_HOSTNAME"
./scripts/update-dns.sh upsert rashmidevops.xyz "$ALB_HOSTNAME"
```
The script auto-detects this is the apex domain and creates an Alias A
record (a plain CNAME isn't allowed at the root of a domain — only on
subdomains).

### GATE 5 — Confirm the app is actually live
```bash
sleep 60
curl -s -o /dev/null -w "app: %{http_code}\n" https://rashmidevops.xyz
curl -s https://rashmidevops.xyz/health
```
**Expect:** `200`, and real JSON with a `version` field matching the tag
CI just built. If `000` here but everything else checks out, it's very
likely your local machine's DNS cache, not the actual deployment — test
in a real browser too before assuming something's broken.

**You now have a fully working, deployed application.** Everything below
is monitoring/alerting on top of it — optional, but recommended.

---

## Step 8 — Install monitoring (Prometheus + Alertmanager + Grafana)

**One-time environment check first** — if Helm was ever installed via
`snap` (common default on Ubuntu), it fails inside WSL with `internal
error: timeout waiting for snap system profiles to get updated`. Check
once:
```bash
which helm
```
If this shows `/snap/bin/helm`, replace it before continuing:
```bash
sudo snap remove helm 2>/dev/null || true
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o get_helm.sh
chmod +x get_helm.sh
sudo ./get_helm.sh
rm get_helm.sh
hash -r
helm version   # should print cleanly now, no snap error
```

**Optional — set a Slack webhook** so Alertmanager can actually notify
somewhere:
```bash
export SLACK_WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
```

**Install:**
```bash
./scripts/install-monitoring.sh ../employee-task-app
```
4 phases: namespace + Slack secret, Alertmanager, Prometheus (configured
to scrape the real backend's `/metrics`), Grafana (your dashboard JSON
pre-loaded via ConfigMap sidecar). Ends printing the Grafana admin
password.

### GATE 6 — Confirm Prometheus is actually scraping the real backend

This matters — a Prometheus that's "Running" but not successfully
scraping anything is useless and easy to miss if you don't check.

```bash
kubectl -n monitoring port-forward svc/prometheus-server 9090:80
```
Open `http://localhost:9090/targets` in your browser. **Expect:** a
target named `employee-task-backend` showing **State: UP**.

---

## Step 9 — Open Grafana

In a separate terminal (leave the port-forward above running if you still
want it):
```bash
kubectl -n monitoring port-forward svc/grafana 3000:80
```
Open `http://localhost:3000` — login `admin` / the password from Step 8.

Go to **Dashboards** in the left sidebar — **Application Overview**
should already be there (auto-imported), showing live metrics from your
real running app.

---

## What you have running at this point

- **Terraform**: VPC, EKS, RDS, ECR, ACM, Route53, IAM, EC2 — from one apply
- **GitHub Actions**, OIDC-authenticated (no stored AWS keys): test → scan
  → build → push → auto-commit the deploy
- **ArgoCD**: GitOps, auto-synced, self-healing, watching your own repo
- **The app itself**, live at `https://rashmidevops.xyz` over real HTTPS
- **ArgoCD UI**, live at `https://argocd.rashmidevops.xyz`
- **Prometheus + Alertmanager + Grafana**, in-cluster, scraping real
  metrics, with 3 real alert rules (`APIDown`, `HighErrorRate`,
  `SlowAPIResponse`) — internal only, accessed via `port-forward`, not a
  public hostname (deliberate — keeps this project to 2 public hostnames
  total)

---

## Quick reference: all 6 gates in this runbook

| Gate | After step | Checks |
|---|---|---|
| 1 | terraform apply | Nodes Ready, Secret has 7 keys |
| 2 | sync-config.sh | values.yaml has real ECR/cert/host, not empty |
| 3 | install-cluster-addons.sh | ArgoCD UI returns 200 |
| 4 | first CI/CD run | ArgoCD App Healthy, pods Running |
| 5 | DNS upsert (app) | App returns 200 with real version in JSON |
| 6 | install-monitoring.sh | Prometheus target State: UP |

A gate failing doesn't mean start over — it tells you exactly which layer
to look at next, instead of guessing across the whole stack.

When you're done for the session: see `DESTROY.md` for the teardown
runbook (same gate-based approach, in reverse).