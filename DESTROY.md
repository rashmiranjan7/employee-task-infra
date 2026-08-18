# DESTROY.md — Full Teardown Runbook

Written after actually getting stuck doing this the "obvious" way. The root
cause of every stuck destroy we hit: **deleting things in an order that
orphans a resource the deleted controller was supposed to clean up**, or
**not verifying a delete actually finished before moving to the next step**.

This runbook fixes both by putting a **verification gate** after every
step that matters. Do not skip a gate because "it's probably done by now."

Total time: ~20-30 minutes, most of it waiting on the final `terraform
destroy` (EKS + NAT Gateway deletion are the slow parts).

---

## The one rule that matters most

**Never uninstall the AWS Load Balancer Controller (or delete its
namespace/cluster) before every ALB it created is confirmed gone.**

The controller is the only thing that turns "I deleted a Kubernetes
Ingress" into "the actual AWS Application Load Balancer is deleted." If you
remove the controller first, any ALB it hasn't finished tearing down yet
becomes **orphaned** — it keeps running in AWS, still attached to your
VPC's subnets, with nothing left to finish deleting it. Terraform then
can't delete the VPC/subnets either, because AWS won't let you delete a
subnet with a live network interface still in it. This is exactly what
happened the first time we did this teardown.

The fix isn't complicated: **delete Ingresses, WAIT and VERIFY the ALBs
are actually gone, THEN uninstall the controller.** Every gate below
exists because of this one rule.

---

## Step 0 — Confirm your shell actually works

Skip this and you risk debugging a "stuck resource" that's actually just a
broken terminal session (this happened to us — wrong Linux user, no DNS
resolver, no AWS credentials, all at once, all unrelated to AWS itself).

```bash
whoami
# expect: your normal Linux username (not "adduser" or anything unfamiliar)

cat /etc/resolv.conf
# expect: a "nameserver" line — if "No such file or directory", run:
#   sudo bash -c 'echo "nameserver 8.8.8.8" > /etc/resolv.conf'

aws sts get-caller-identity
# expect: your AWS account JSON, not a connection error

aws eks update-kubeconfig --name employee-task-dev --region us-east-1
kubectl get nodes
# expect: your nodes, STATUS Ready
```

If any of these fail, fix it before continuing — do not try to interpret
an AWS/Terraform error until you've confirmed the basics work.

---

## Step 1 — Uninstall monitoring (if installed)

Newest addition, safe to remove first — nothing else depends on it.

```bash
helm uninstall grafana -n monitoring 2>/dev/null || true
helm uninstall prometheus -n monitoring 2>/dev/null || true
helm uninstall alertmanager -n monitoring 2>/dev/null || true
kubectl delete namespace monitoring --ignore-not-found
```

No gate needed here — this namespace has no Ingress/ALB, nothing for it to
orphan.

---

## Step 2 — Delete the ArgoCD Application

This stops ArgoCD's `selfHeal` from re-creating anything we delete in the
next steps (ArgoCD watching a resource you're trying to manually delete
will just put it back — we hit this earlier today with a cert ARN change).

```bash
cd ~/projects   # or wherever your 3 repo folders live
kubectl delete -f employee-task-gitops/apps/dev-application.yaml --ignore-not-found
```

**If this says "the path ... does not exist"**: you're not in the right
directory, or the file was moved. Find it first:
```bash
find . -name "dev-application.yaml" 2>/dev/null
```
Use whatever path that returns instead of guessing.

---

## Step 3 — Delete BOTH Ingresses directly

This is the step that actually removes the ALBs — deleting the ArgoCD
`Application` in step 2 does NOT automatically clean up the Ingress
resources it created (there's no cascade-delete finalizer configured on
it), so this step is not optional even if step 2 succeeded.

```bash
kubectl -n employee-task-dev delete ingress employee-task-dev-ingress --ignore-not-found
kubectl -n argocd delete ingress argocd-server --ignore-not-found
```

---

## Step 4 — GATE: Confirm both ALBs are actually gone

**This is the gate that got skipped last time. Do not skip it this time.**
ALB deletion is asynchronous — `kubectl delete ingress` returns instantly,
but the actual AWS load balancer can take 1-3 minutes to fully disappear.

```bash
sleep 90
aws elbv2 describe-load-balancers --region us-east-1 \
  --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-')].{Name:LoadBalancerName,State:State.Code}" \
  --output table
```

**Expect:** completely empty table.

**If NOT empty:** wait another 60-90 seconds and re-check. Repeat up to
~5 minutes total. Do not proceed to Step 6 (uninstalling the controller)
until this is empty — proceeding anyway is exactly what orphans the ALB.

**If it's still there after 5 minutes:** the controller may be stuck.
Check its logs before doing anything manual:
```bash
kubectl -n kube-system logs -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50
```

---

## Step 5 — Delete both DNS records

```bash
cd employee-task-infra
./scripts/update-dns.sh delete rashmidevops.xyz
./scripts/update-dns.sh delete argocd.rashmidevops.xyz
```

Both print `OK: ... deleted.` — the script auto-detects whether each
record is a CNAME (subdomains) or an Alias A record (the apex domain) and
deletes the right type automatically, so you don't need to know which is
which.

---

## Step 6 — NOW it's safe to uninstall ArgoCD and the ALB Controller

Only run this after Step 4's gate came back empty.

```bash
helm uninstall argocd -n argocd
kubectl delete namespace argocd
helm uninstall aws-load-balancer-controller -n kube-system
```

**"These resources were kept due to the resource policy" for 3
CustomResourceDefinitions** is normal, expected Helm behavior (CRDs are
deliberately not deleted on uninstall, to protect data if you reinstall
later) — not an error, and not something to clean up separately. They get
removed automatically when the whole EKS cluster is destroyed in Step 8.

---

## Step 7 — GATE: Double-check for orphaned target groups

Even when the ALB itself is gone, its target groups can sometimes survive
independently if the controller was interrupted mid-cleanup. These are a
second, separate thing from the ALB and won't show up in Step 4's check.

```bash
aws elbv2 describe-target-groups --region us-east-1 \
  --query "TargetGroups[?contains(TargetGroupName, 'k8s-employee') || contains(TargetGroupName, 'k8s-argocd')].TargetGroupArn" \
  --output text
```

**Expect:** empty.

**If NOT empty** (this happened to us): delete each one directly —
the controller being gone doesn't block this, target groups can always be
deleted directly via the API:
```bash
for TG in $(aws elbv2 describe-target-groups --region us-east-1 \
  --query "TargetGroups[?contains(TargetGroupName, 'k8s-employee') || contains(TargetGroupName, 'k8s-argocd')].TargetGroupArn" \
  --output text); do
  echo "Deleting: $TG"
  aws elbv2 delete-target-group --target-group-arn "$TG" --region us-east-1
done
```
Re-run the check above until it's empty before continuing.

**Also double check no ALB survived either**, in case Step 4 was checked
too early and something new appeared since:
```bash
aws elbv2 describe-load-balancers --region us-east-1 \
  --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-')].LoadBalancerName" --output text
```
If anything's listed, delete it directly:
```bash
ALB_ARN=$(aws elbv2 describe-load-balancers --region us-east-1 \
  --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-')].LoadBalancerArn" --output text)
aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region us-east-1
sleep 90
```
Then re-check target groups again (deleting an ALB doesn't auto-delete its
target groups) before moving to Step 8.

---

## Step 8 — `terraform destroy`

Only run this once Steps 4 and 7 are both confirmed empty.

```bash
cd terraform
terraform destroy -var-file=terraform.tfvars
```
Type `yes`. Takes ~10-15 minutes — EKS cluster and NAT Gateway deletion
are the slowest parts, this is normal, do not interrupt it.

**Expect:** `Destroy complete! Resources: 64 destroyed.`

**If it still gets stuck** on a VPC, subnet, or security group resource
(shouldn't happen if Steps 4 and 7 were actually clean, but just in
case): open a **second terminal**, don't cancel the running destroy, and
check what's still attached:
```bash
VPC_ID=$(aws ec2 describe-vpcs --region us-east-1 \
  --filters "Name=tag:Name,Values=employee-task-dev-vpc" \
  --query "Vpcs[0].VpcId" --output text)

aws ec2 describe-network-interfaces --region us-east-1 \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query "NetworkInterfaces[].{Id:NetworkInterfaceId,Description:Description,Status:Status}" \
  --output table
```
Whatever shows up here (usually another leftover ALB/NLB ENI, or a lingering ECS/Lambda ENI from something unrelated) is the actual blocker —
identify what created it and delete that resource directly, then let the
stuck `terraform destroy` continue (it retries automatically) or re-run it.

---

## Step 9 — Final verification: confirm nothing billable is left

Run every one of these — each one covers a different real cost driver,
and it's cheap/free to check all of them every time.

```bash
aws ec2 describe-instances --region us-east-1 --filters "Name=tag:Project,Values=employee-task" \
  --query "Reservations[].Instances[?State.Name!='terminated'].InstanceId"

aws rds describe-db-instances --region us-east-1 \
  --query "DBInstances[?contains(DBInstanceIdentifier,'employee-task')].DBInstanceIdentifier"

aws eks list-clusters --region us-east-1

aws elbv2 describe-load-balancers --region us-east-1 \
  --query "LoadBalancers[].LoadBalancerName"

aws ec2 describe-nat-gateways --region us-east-1 \
  --filter "Name=state,Values=available,pending" \
  --query "NatGateways[].NatGatewayId"

aws ec2 describe-vpcs --region us-east-1 \
  --filters "Name=tag:Name,Values=employee-task-dev-vpc" \
  --query "Vpcs[].VpcId"

aws ec2 describe-addresses --region us-east-1 \
  --query "Addresses[?Tags[?Key=='Project' && Value=='employee-task']].AllocationId"
```

**Expect:** all seven return empty. The last one (Elastic IPs) is easy to
forget — the NAT Gateway's EIP is billed hourly even when unattached, and
`terraform destroy` normally releases it, but it's worth the extra check.

---

## Step 10 — (Optional) Delete the Terraform state backend

Only do this if you're fully done with the project for good — keeping the
bucket means a future rebuild's Step 0 (bootstrap-backend.sh) is already
done.

```bash
aws s3 rb s3://employee-task-tfstate-897074277336 --force
aws dynamodb delete-table --table-name employee-task-tf-locks --region us-east-1
```

---

## Summary: the order that actually works

```
1. monitoring (helm uninstall × 3, delete namespace)
2. ArgoCD Application (kubectl delete)
3. Both Ingresses (kubectl delete)          ← creates the ALB deletion requests
4. GATE: verify both ALBs gone               ← DO NOT SKIP
5. DNS records (update-dns.sh delete × 2)
6. ArgoCD + ALB Controller (helm uninstall)  ← only after gate 4 passes
7. GATE: verify no orphaned target groups or ALBs
8. terraform destroy
9. Final billing verification (7 checks)
10. (optional) delete state backend
```

The two gates (steps 4 and 7) are the entire fix. Everything else was
already correct — it was the *order*, and skipping verification between
steps, that caused the stuck destroy.