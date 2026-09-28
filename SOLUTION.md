# SOLUTION

**ALB URL:** http://k8s-nodeapp-nodeapp-bc46885b8a-895745297.eu-central-1.elb.amazonaws.com (`/` and `/health` return HTTP 200)
**Cluster:** `devops-test-eks`, EKS 1.36, Fargate only, `eu-central-1`
**Terraform state:** S3 backend, bucket `devops-test-tfstate-056300054271`, key `eks/terraform.tfstate` (versioned, SSE-S3, public access blocked, lockfile locking). Read access on request.

## How it is deployed

```bash
cd terraform && terraform init && terraform apply
aws eks update-kubeconfig --name devops-test-eks --region eu-central-1
ECR=$(terraform output -raw ecr_repository_url); TAG=$(git rev-parse --short HEAD)
docker build -t $ECR:$TAG ../app && docker push $ECR:$TAG   # ECR tags are immutable
kubectl apply -f ../k8s/                                     # deployment.yaml pins $TAG
```

## What was broken and how I fixed it

**Application / image**
1. Server bound to `127.0.0.1` by default, unreachable from probes and the ALB. Now `0.0.0.0`.
2. Every `GET /` stored a 32 MiB buffer forever (an "audit log" nothing read), which would OOM under the 256Mi limit. Removed.
3. SIGTERM handler called `process.exit(0)` and dropped in-flight requests. Now `server.close()` with a timeout.
4. Dockerfile used `npm install` without a lockfile and Node 20 (EOL). Now `npm ci`, Node 22, `.dockerignore`, non-root UID.

**Kubernetes**
5. Ingress lacked `target-type: ip`, which Fargate requires.
6. `:latest` with `imagePullPolicy: Always`. Now an immutable git-sha tag (and ECR tag immutability).
7. One replica. Now two, spread across zones. Added seccomp `RuntimeDefault` and disabled SA token automount.
8. `kubectl apply -f k8s/` runs alphabetically, so the Deployment ran before the namespace. Renamed to `00-namespace.yaml`.

**Terraform**
9. Fargate profile `apps` selected namespace `default`, but the app runs in `nodeapp`. Pods would stay Pending. Now uses `var.app_namespace`.
10. The `kube-system` profile matched only `k8s-app=kube-dns`, so the LB controller pods would stay Pending. Now the whole namespace.
11. IRSA trust named ServiceAccount `alb-controller`, but the chart creates `aws-load-balancer-controller`. `AssumeRoleWithWebIdentity` would fail.
12. Public subnets lacked `kubernetes.io/role/elb=1`, so the controller could not discover subnets for the ALB.
13. Pods and control-plane ENIs were placed in extra subnets named "public-data" but routed via NAT (misleading, unnecessary). Removed; everything uses the private subnets.
14. `cluster_version = 1.30` is past end of extended support. Now 1.36 (standard support).
15. LB controller chart 1.8.2 with policy v2.8.2 (v2 line no longer actively developed). Now chart 3.5.0 with the matching v3.5.0 IAM policy. The `http` provider is declared.
16. No remote state. Added an S3 backend (Terraform >= 1.10 for `use_lockfile`).
17. ECR tags were mutable. Now `IMMUTABLE`.

## Noticed, deliberately not fixed

- **Single NAT gateway:** one AZ failure cuts egress for all pods. Kept for cost; commented in code.
- **EKS public endpoint open to 0.0.0.0/0** (IAM-authenticated). Would restrict by CIDR or go private plus VPN.
- **HTTP only:** no ACM/TLS or WAF, because no domain was provided. The ALB security group is open on port 80.
- **No HPA, PDB, NetworkPolicy, alarms or dashboards, and no CI/CD.** The image build and push is a manual step.
- **Cluster-admin for the creator role** instead of scoped access entries.
- **Housekeeping debt:** `kube-proxy` and `vpc-cni` add-ons are pointless on Fargate-only; ECR `force_delete = true` (easy teardown); the IAM policy JSON is downloaded at plan time instead of vendored; the state bucket was created by CLI, not IaC.

## Architecture answers

1. **Subnet layout.** Two public subnets route to the IGW and hold only the ALB and the NAT gateway. Two private subnets, in the same two AZs, hold Fargate pods and control-plane ENIs and reach the internet only through NAT. This keeps the ALB as the single ingress path and limits blast radius. For production I would add a third AZ, isolated data subnets without a default route, larger CIDRs (each Fargate pod uses a VPC IP), VPC endpoints (ECR, S3, STS, Logs) and flow logs.
2. **NAT.** With `single_nat_gateway = true`, one NAT sits in the first public subnet (one AZ). If that AZ fails, all private egress fails cluster-wide (image pulls, STS for IRSA, AWS APIs), and cross-AZ traffic is billed. For production I would run one NAT per AZ with a route table per AZ (roughly $35-40 per month each plus data) and add VPC endpoints. It trades cost for AZ isolation.
3. **IAM / IRSA.** Fargate pods have no node role to borrow, and a shared role would give every pod the same permissions. IRSA gives one ServiceAccount short-lived, least-privilege credentials through STS. It requires the cluster OIDC issuer registered as an IAM OIDC provider, and a role trust policy allowing `sts:AssumeRoleWithWebIdentity` from it, with conditions `aud = sts.amazonaws.com` and `sub = system:serviceaccount:kube-system:aws-load-balancer-controller`. The ServiceAccount carries the role ARN annotation.
4. **Subnet discovery.** For an internet-facing ALB, the controller picks subnets in the cluster VPC tagged `kubernetes.io/role/elb=1` (plus the cluster tag), one per AZ, unless the `subnets` annotation overrides it. If discovery fails, the Ingress never gets an address and its events show an auto-discovery error. I would check `kubectl describe ingress`, the controller logs, `aws ec2 describe-subnets` filtered by the role tag, and the controller's `vpcId` and EC2 permissions.
5. **Fargate vs node groups.** Fargate removes node patching and gives per-pod isolation, but costs more per vCPU/GB, starts pods slower, and has no DaemonSets, privileged pods, GPUs or EBS volumes. I would use Fargate for small, bursty, stateless services with a small ops budget. I would use node groups for steady high-density workloads, DaemonSet-based tooling, GPUs, EBS-backed state or custom AMIs.
6. **Secrets.** Keep them in AWS Secrets Manager or SSM Parameter Store and sync them into the pod with External Secrets Operator, or read them with the SDK using IRSA (the Secrets Store CSI driver runs as a DaemonSet, which Fargate does not support). The trust boundary is an IAM role bound to the app's ServiceAccount and limited to specific secret ARNs. Nothing lives in the repo, the image or plain manifests, and Kubernetes secrets are envelope-encrypted with the cluster KMS key.
7. **Upgrades.** Upgrade the control plane one minor version at a time (the API stays available), after checking for removed APIs and updating add-ons and the LB controller. Then restart the workloads so Fargate pods come up on the new version. With 2 or more replicas, zone spread and a PDB there is no downtime. For stateful workloads I would snapshot first, roll one pod at a time with replication checks, or build a blue/green cluster and migrate the data.
8. **Observability and SLOs.** Minimum: ALB metrics (5xx, latency, healthy targets), pod CPU/memory/restarts, centralized stdout and control-plane logs, and an external probe on `/health`. I would page on the target 5xx ratio above 1% for 5 minutes, roughly a 10x error-budget burn against a 99.9% availability SLO.

## Self-review against the gold rule

**I would defend:** the network layout and subnet roles, IRSA scoped to one ServiceAccount, non-root read-only pods with probes and seccomp, immutable image tags, versioned remote state, pinned provider and chart versions, and a clean `terraform apply` from zero.
**Known debt:** single NAT, open API endpoint, HTTP only, no autoscaling/PDB/NetworkPolicy, no alarms, no CI/CD, creator-admin access, a manual image build.

## What I would harden next

TLS with ACM and a domain, WAF, one NAT per AZ, a restricted or private API endpoint, a CI pipeline (`terraform plan` on PR, image scanning and signing), PDB and HPA, alarms and dashboards, External Secrets, scoped access entries, a vendored IAM policy, and a state bucket managed as code.
