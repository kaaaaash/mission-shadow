# MISSION SHADOW — DAY 1-2 HANDOVER

**Operator:** kaash  
**Date:** 12-13 May 2026  
**Status:** Days 1-2 Complete  
**Duration:** ~4 hours total

---

## MISSION BRIEF

**Project:** Mission Shadow — A production-grade progressive delivery platform  
**Goal:** Deploy services to Kubernetes with canary rollouts, traffic splitting, and automatic rollback  
**Stack:** AWS EKS, Terraform, Argo Rollouts, Istio, Prometheus, Grafana, FastAPI  
**Budget:** $118.44 USD student credits (132 days remaining)  
**Burn Rate:** ~$0.12/hr (~$2.88/day) when cluster is running  

---

## WHAT WE ACCOMPLISHED

### Day 1 — Recon & Setup (55 minutes)

**Environment:** Windows 11 + WSL2 (Ubuntu 26.04)

**Tools Installed:**
- AWS CLI v2.34.45
- Terraform v1.8.5
- kubectl v1.36.0
- Helm v3.20.2
- Docker v29.1.3
- eksctl v0.226.0

**AWS Setup:**
- Account ID: `974066991644`
- Region: `us-east-1`
- Root credentials configured
- shadow-operator IAM user created (later switched back to root for cluster access)

**Project Structure Created:**
```
~/mission-shadow/
├── app/          # Payment service (FastAPI) — Day 3
├── infra/        # Terraform — COMPLETE
├── k8s/          # Argo Rollouts, Istio manifests — Day 4-5
├── monitoring/   # Prometheus, Grafana — Day 6
├── chaos/        # Failure injection scripts — Day 6
└── docs/         # This file + architecture diagrams
```

**Terraform Init:**
- Created `main.tf`, `variables.tf`, `outputs.tf`
- Initialized with EKS + VPC modules
- Plan verified: 51 resources ready

---

### Day 2 — Infiltration (3+ hours)

**Challenges Encountered:**
1. ❌ EKS 1.29 AMI not supported → upgraded to 1.30
2. ❌ t3.medium not free tier → switched to t3.small
3. ❌ IAM auth issues → multiple iterations with shadow-operator vs root
4. ❌ DNS lookup failure after cluster rebuild → kubeconfig refresh
5. ✅ Final fix: Added `enable_cluster_creator_admin_permissions = true` to Terraform

**Infrastructure Deployed:**
- ✅ EKS cluster: `mission-shadow`
- ✅ Kubernetes v1.30.14
- ✅ VPC with public/private subnets (10.0.0.0/16)
- ✅ NAT gateway (single, to save costs)
- ✅ Node group: 1x t3.small instance
- ✅ kubectl authenticated and connected

**Final Verification:**
```bash
kubectl get nodes
NAME                        STATUS   ROLES    AGE   VERSION
ip-10-0-1-71.ec2.internal   Ready    <none>   18m   v1.30.14-eks-4136f65
```

**Cluster Endpoint:**
```
https://[REDACTED].yl4.us-east-1.eks.amazonaws.com
```

---

## TERRAFORM CONFIGURATION

**File:** `~/mission-shadow/infra/main.tf`

**Key Settings:**
- Region: `us-east-1`
- Cluster Name: `mission-shadow`
- Cluster Version: `1.30`
- Instance Type: `t3.small`
- Node Count: 1 (min=1, max=2, desired=1)
- Networking: Single NAT gateway to minimize costs
- IAM: `enable_cluster_creator_admin_permissions = true`

**Modules Used:**
- `terraform-aws-modules/vpc/aws` v5.1.2
- `terraform-aws-modules/eks/aws` v20.8.4

---

## CRITICAL DAILY WORKFLOW

**Every night before shutdown:**
```bash
cd ~/mission-shadow/infra
terraform destroy
```
Type `yes` to confirm. Saves ~$2.88/day.

**Every morning to resume:**
```bash
cd ~/mission-shadow/infra
terraform apply
```
Type `yes`. Takes ~12-15 minutes to provision.

**After apply, reconnect kubectl:**
```bash
aws eks update-kubeconfig --region us-east-1 --name mission-shadow
kubectl get nodes
```

---

## LESSONS LEARNED

1. **Ubuntu 26.04 is too new** — HashiCorp repo doesn't support it yet. Installed Terraform manually via binary.

2. **EKS has no free tier** — Even t3.micro won't work for nodes. Smallest viable: t3.small (~$0.02/hr).

3. **IAM with EKS is painful** — Cluster creator gets auto-access, but adding other users requires aws-auth ConfigMap edits. For 7-day projects, just use root.

4. **Always check AMI compatibility** — AWS deprecates old Kubernetes versions. Start with latest stable (1.30+).

5. **Destroy nightly** — EKS control plane alone is $0.10/hr. That's $72/month if left running.

6. **Multiple AWS accounts strategy** — With multiple email IDs, you can rotate through fresh $100 credit pools. Smart.

---

## NEXT STEPS — DAY 3

**Mission:** Build and deploy the payment service (v1)

**Tasks:**
1. Create FastAPI app in `~/mission-shadow/app/`
   - Endpoints: `/pay`, `/health`, `/fail`, `/slow`
   - `/fail` returns 500 (chaos trigger)
   - `/slow` adds 2s delay (latency injection)

2. Write Dockerfile

3. Build and push to ECR:
   ```bash
   aws ecr create-repository --repository-name mission-shadow --region us-east-1
   ```

4. Deploy v1 to EKS as a basic Deployment + Service

5. Verify with `curl` or port-forward

**Estimated Time:** 2-3 hours

---

## DAY 4-5 PREVIEW

- Install Argo Rollouts
- Install Istio
- Convert Deployment → Rollout with canary strategy
- Configure VirtualService for traffic splitting (5% canary)
- Deploy v2 with gradual rollout

---

## DAY 6 PREVIEW

- Install Prometheus + Grafana
- Define SLIs: error rate <1%, P95 latency <300ms
- Configure Argo analysis templates
- Inject failures: pod kill, CPU stress, network delay
- Trigger automatic rollback

---

## DAY 7 PREVIEW

- Final chaos test with screenshots
- Create Grafana dashboard (screenshot-able)
- Write final dossier PDF with architecture diagrams
- Clean GitHub README with setup instructions
- **DESTROY EVERYTHING** — final `terraform destroy`

---

## COST TRACKING

**Spent So Far:** ~$3-5 (multiple apply/destroy cycles during debugging)  
**Remaining Credits:** ~$113-115 USD  
**Estimated Total Project Cost:** $15-20 if destroyed nightly  

---

## REPOSITORY STATE

**Git Status:** Not initialized yet  
**VSCode:** Connected to WSL, mission-shadow folder open  

**TODO for next session:**
```bash
cd ~/mission-shadow
git init
git add .
git commit -m "Day 1-2: Infrastructure provisioned, EKS live"
git remote add origin <your-github-repo>
git push -u origin main
```

---

## TROUBLESHOOTING REFERENCE

**If kubectl fails with auth error:**
```bash
aws sts get-caller-identity  # Check current user
aws eks update-kubeconfig --region us-east-1 --name mission-shadow
rm -rf ~/.kube/cache
kubectl get nodes
```

**If nodes won't provision:**
- Check instance type is supported (t3.small minimum)
- Verify Kubernetes version is recent (1.30+)
- Check AWS service quotas for EC2 in us-east-1

**If Terraform state is corrupted:**
```bash
terraform state list  # Show all resources
terraform destroy     # Nuclear option
terraform apply       # Rebuild from scratch
```

---

## COMMANDS CHEAT SHEET

**AWS:**
```bash
aws sts get-caller-identity
aws eks list-clusters --region us-east-1
aws eks describe-cluster --name mission-shadow --region us-east-1
```

**Terraform:**
```bash
terraform init
terraform plan
terraform apply
terraform destroy
terraform state list
```

**Kubernetes:**
```bash
kubectl get nodes
kubectl get pods -A
kubectl get svc -A
kubectl logs <pod-name>
kubectl describe pod <pod-name>
```

---

## FINAL NOTES

- You crushed 2 days in 4 hours. Ahead of schedule.
- The auth debugging was brutal but you learned EKS IAM the hard way.
- Tomorrow starts the fun part — actual code.
- Don't forget to destroy tonight.

**Bravo 6. Going dark.**

---

*This handover document lives at: `~/mission-shadow/docs/DAY1-2_HANDOVER.md`*
