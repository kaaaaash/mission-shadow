# MISSION SHADOW — DAY 5 HANDOVER

**Operator:** kaash  
**Date:** 18 May 2026  
**Status:** Service Mesh Operational + Traffic Splitting Live  
**Duration:** ~4 hours (debugging hell included)

---

## EXECUTIVE SUMMARY

Day 5 was the **integration gauntlet**. Installed Istio service mesh, fought webhook timeouts, crashed ingress gateways, empty server replies, pod scheduling failures, and Argo integration errors. Every layer of the stack broke at least once.

Then it all clicked. External traffic → ELB → Istio Gateway → VirtualService → weighted routing → stable/canary pods. Argo Rollouts controlling traffic percentages automatically. Kiali showing live traffic flow in real-time.

**Key Lesson:** Service mesh transforms "Kubernetes running containers" into "production-grade progressive delivery platform." But the integration tax is brutal.

---

## MISSION OBJECTIVES

**Primary:**
- Install Istio service mesh (control plane + ingress gateway)
- Enable Envoy sidecar injection on shadow-payment pods
- Create VirtualService + DestinationRule for traffic routing
- Integrate Argo Rollouts with Istio for automatic traffic weight management
- Deploy v2 canary with weighted traffic splitting (stable vs canary)

**Secondary (learned the hard way):**
- Debug webhook timeout issues blocking pod creation
- Fix ingress gateway crash loop (missing certs + auth bootstrap)
- Solve empty server replies (Gateway + VirtualService misconfiguration)
- Scale nodegroup to handle Kiali + Prometheus scheduling
- Create dedicated stable/canary services for Argo integration

---

## INFRASTRUCTURE STATE

### Starting Position

**From Day 4:**
- ✅ EKS cluster running (1x t3.medium node)
- ✅ Argo Rollouts controller operational
- ✅ Payment service v3 deployed via canary (4 replicas)
- ✅ LoadBalancer service exposing traffic

**What needed to change:**
- Replace basic LoadBalancer with Istio-managed ingress
- Inject Envoy sidecars into all pods
- Add traffic routing intelligence at the mesh layer

---

## ISTIO INSTALLATION

### Step 1 — Download Istio

```bash
cd ~
curl -L https://istio.io/downloadIstio | sh -
cd istio-1.22.0
export PATH=$PWD/bin:$PATH
```

**Version Installed:**
```
istioctl version
client version: 1.22.0
```

---

### Step 2 — Install Istio Control Plane

**Initial attempt (minimal profile):**
```bash
istioctl install --set profile=minimal -y
```

**Resources Created:**
- Namespace: `istio-system`
- Deployment: `istiod` (control plane)
- Service: `istiod` (webhook + discovery)
- ValidatingWebhookConfiguration (for sidecar injection)

**Verification:**
```bash
kubectl get pods -n istio-system
NAME                      READY   STATUS    RESTARTS   AGE
istiod-7d6b9f5c9d-8xk2m   1/1     Running   0          2m13s
```

✅ **Control plane running.**

---

### Step 3 — Install Istio Ingress Gateway

**Problem:** Minimal profile doesn't include ingress gateway. Need to add it manually.

**Initial broken attempt (handcrafted):**
```bash
# DON'T DO THIS - creates broken ingress
kubectl apply -f samples/bookinfo/networking/bookinfo-gateway.yaml
```

**Result:** Ingress pod crashed with:
```
Envoy proxy is NOT ready: config not received from Pilot
gRPC config stream closed: 14, connection error
```

**Root cause:** Missing root certificates, broken xDS/SDS authentication, no proper bootstrap config.

---

**Working Fix — Use istioctl:**

```bash
istioctl install --set profile=default -y
```

**What this does:**
- Installs `istiod` control plane
- Installs `istio-ingressgateway` deployment + LoadBalancer service
- Configures proper Envoy bootstrap with:
  - Root certificates from istiod
  - xDS server connection to istiod:15012
  - SDS for dynamic secret discovery

**Verification:**
```bash
kubectl get pods -n istio-system
NAME                                    READY   STATUS    RESTARTS   AGE
istio-ingressgateway-5c7d9f7b9f-7k8xm   1/1     Running   0          3m42s
istiod-7d6b9f5c9d-8xk2m                 1/1     Running   0          8m15s

kubectl get svc -n istio-system
NAME                   TYPE           CLUSTER-IP       EXTERNAL-IP                                                              PORT(S)
istio-ingressgateway   LoadBalancer   10.100.234.156   a3f5e8d7c... .elb.us-east-1.amazonaws.com   15021:31854/TCP,80:32510/TCP,443:31742/TCP
istiod                 ClusterIP      10.100.89.234    <none>                                                                   15010/TCP,15012/TCP,443/TCP,15014/TCP
```

✅ **Ingress gateway running with external LoadBalancer.**

---

## SIDECAR INJECTION

### Step 1 — Enable Auto-Injection

**Label default namespace:**
```bash
kubectl label namespace default istio-injection=enabled
kubectl get namespace -L istio-injection
```

**Output:**
```
NAME              STATUS   AGE   ISTIO-INJECTION
default           Active   3d    enabled
istio-system      Active   15m   
kube-node-lease   Active   3d    
kube-public       Active   3d    
kube-system       Active   3d    
```

---

### Step 2 — Restart Rollout to Inject Sidecars

```bash
kubectl rollout restart rollout shadow-payment
```

**Expected:** Pods recreate with 2 containers (app + istio-proxy)

**What actually happened:**
```
Events:
  Type     Reason            Message
  ----     ------            -------
  Warning  FailedCreate      Error creating: Internal error occurred: failed calling webhook
                             "sidecar-injector.istio.io": Post "https://istiod.istio-system.svc:443/inject?timeout=10s": 
                             context deadline exceeded
```

**Problem:** Sidecar injection webhook timing out. Pods stuck in Pending, couldn't be created.

---

### The Webhook Timeout Hell

**Root Cause:** `istiod` webhook service unreachable or overloaded.

**Attempted Fix #1 — Restart istiod:**
```bash
kubectl rollout restart deployment istiod -n istio-system
```
Still timing out.

**Attempted Fix #2 — Check webhook config:**
```bash
kubectl get validatingwebhookconfiguration istiod-default-validator -o yaml
```

Found webhook pointing to correct service endpoint, but still failing.

**Working Fix — Temporarily disable injection to recover:**

```bash
kubectl label namespace default istio-injection-
kubectl rollout restart rollout shadow-payment
```

Pods created successfully without sidecars. App back online.

**Then re-enable after istiod stabilized:**
```bash
kubectl delete pod -n istio-system -l app=istiod  # Force fresh restart
sleep 60  # Wait for webhook to register

kubectl label namespace default istio-injection=enabled
kubectl rollout restart rollout shadow-payment
```

**Verification:**
```bash
kubectl get pod -l app=shadow-payment -o jsonpath='{.items[0].spec.containers[*].name}'
# Output: payment-service istio-proxy
```

✅ **Sidecars injected successfully.**

---

## TRAFFIC ROUTING CONFIGURATION

### The Problem with Basic LoadBalancer

**Before Istio:** Kubernetes LoadBalancer sends traffic directly to pods via kube-proxy.

**Limitations:**
- No weighted traffic splitting
- No header-based routing
- No progressive canary control

**After Istio:** Traffic flows through:
```
Internet → ELB → Istio Gateway → VirtualService → DestinationRule → Pods (Envoy sidecars)
```

**Advantages:**
- Weighted routing (95% stable, 5% canary)
- Header-based routing (canary-test: true)
- Automatic integration with Argo Rollouts
- Circuit breaking, retries, fault injection

---

### Step 1 — Create Gateway

**File:** `k8s/istio-gateway.yaml`

```yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: shadow-gateway
  namespace: default
spec:
  selector:
    istio: ingressgateway  # Matches istio-ingressgateway pods
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
```

**Apply:**
```bash
kubectl apply -f k8s/istio-gateway.yaml
```

**What this does:**
- Configures Istio ingress gateway to listen on port 80
- Accepts traffic from any host (`*`)
- Routes to VirtualServices attached to this gateway

---

### Step 2 — Create Stable + Canary Services

**Problem:** Argo Rollouts needs separate services for stable vs canary traffic.

**Before (single service):**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: shadow-payment
spec:
  selector:
    app: shadow-payment  # Selects ALL pods
```

**This doesn't work** because we need to route traffic to specific pod versions.

---

**Solution:** Create 3 services:

**File:** `k8s/services.yaml`

```yaml
---
# Root service (for service mesh discovery)
apiVersion: v1
kind: Service
metadata:
  name: shadow-payment
spec:
  selector:
    app: shadow-payment
  ports:
  - port: 8000
    targetPort: 8000
    name: http

---
# Stable service (routes to stable pods only)
apiVersion: v1
kind: Service
metadata:
  name: shadow-payment-stable
spec:
  selector:
    app: shadow-payment
    # Argo adds this label to stable ReplicaSet pods
    rollouts-pod-template-hash: "STABLE_HASH"
  ports:
  - port: 8000
    targetPort: 8000
    name: http

---
# Canary service (routes to canary pods only)
apiVersion: v1
kind: Service
metadata:
  name: shadow-payment-canary
spec:
  selector:
    app: shadow-payment
    # Argo adds this label to canary ReplicaSet pods
    rollouts-pod-template-hash: "CANARY_HASH"
  ports:
  - port: 8000
    targetPort: 8000
    name: http
```

**Important:** Replace `STABLE_HASH` and `CANARY_HASH` with actual values from:

```bash
kubectl get replicaset -l app=shadow-payment
```

**Example:**
```
NAME                          DESIRED   CURRENT   READY   AGE
shadow-payment-5748fc7c9f     4         4         4       2d    # Stable
shadow-payment-7d9f8b6c4d     0         0         0       1d    # Old canary
```

Use `5748fc7c9f` for `STABLE_HASH`.

**Apply:**
```bash
kubectl apply -f k8s/services.yaml
```

---

### Step 3 — Create VirtualService

**File:** `k8s/virtualservice.yaml`

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: shadow-payment
  namespace: default
spec:
  hosts:
  - "*"
  gateways:
  - shadow-gateway
  http:
  - name: primary
    route:
    - destination:
        host: shadow-payment-stable
        port:
          number: 8000
      weight: 100
    - destination:
        host: shadow-payment-canary
        port:
          number: 8000
      weight: 0
```

**What this does:**
- Receives traffic from `shadow-gateway`
- Routes 100% to stable, 0% to canary (initial state)
- Argo Rollouts will update these weights during canary deployment

**Apply:**
```bash
kubectl apply -f k8s/virtualservice.yaml
```

---

### Step 4 — Create DestinationRule

**File:** `k8s/destinationrule.yaml`

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: shadow-payment
  namespace: default
spec:
  host: shadow-payment
  trafficPolicy:
    loadBalancer:
      simple: LEAST_REQUEST
  subsets:
  - name: stable
    labels:
      rollouts-pod-template-hash: "STABLE_HASH"
  - name: canary
    labels:
      rollouts-pod-template-hash: "CANARY_HASH"
```

**Replace `STABLE_HASH` and `CANARY_HASH` with actual ReplicaSet hashes.**

**Apply:**
```bash
kubectl apply -f k8s/destinationrule.yaml
```

---

## ARGO ROLLOUTS + ISTIO INTEGRATION

### Update Rollout Configuration

**File:** `k8s/rollout.yaml`

**Add traffic routing section:**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: shadow-payment
spec:
  replicas: 4
  strategy:
    canary:
      stableService: shadow-payment-stable
      canaryService: shadow-payment-canary
      trafficRouting:
        istio:
          virtualService:
            name: shadow-payment
            routes:
            - primary
      steps:
      - setWeight: 20
      - pause: {duration: 30s}
      - setWeight: 40
      - pause: {duration: 30s}
      - setWeight: 60
      - pause: {duration: 30s}
      - setWeight: 80
      - pause: {duration: 30s}
      - setWeight: 100
  selector:
    matchLabels:
      app: shadow-payment
  template:
    metadata:
      labels:
        app: shadow-payment
    spec:
      containers:
      - name: payment-service
        image: 974066991644.dkr.ecr.us-east-1.amazonaws.com/mission-shadow:v1
        ports:
        - containerPort: 8000
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
```

**Key additions:**
- `stableService: shadow-payment-stable`
- `canaryService: shadow-payment-canary`
- `trafficRouting.istio.virtualService.name: shadow-payment`

**Apply:**
```bash
kubectl apply -f k8s/rollout.yaml
```

---

### The "Degraded" Rollout Error

**After applying updated rollout:**

```bash
kubectl argo rollouts get rollout shadow-payment
```

**Output:**
```
Name:            shadow-payment
Status:          ✖ Degraded
Message:         InvalidSpec: stableService "shadow-payment-stable" not found
                 InvalidSpec: canaryService "shadow-payment-canary" not found
```

**Root Cause:** Services didn't exist yet when rollout was updated.

**Fix:** We already created the services in Step 2, but the rollout checked before they were ready.

**Resolution:**
```bash
kubectl rollout restart rollout shadow-payment
```

After restart, Argo found the services and status changed to `Healthy`.

---

## OBSERVABILITY SETUP

### Step 1 — Install Prometheus

**Istio includes Prometheus addon:**

```bash
kubectl apply -f ~/istio-1.22.0/samples/addons/prometheus.yaml
```

**Verification:**
```bash
kubectl get pods -n istio-system | grep prometheus
prometheus-5d5d6d6fc-7x9km   2/2     Running   0          3m12s
```

---

### Step 2 — Install Kiali

**Kiali = service mesh visualization dashboard**

```bash
kubectl apply -f ~/istio-1.22.0/samples/addons/kiali.yaml
```

**Problem:** Pod stuck in Pending

```bash
kubectl describe pod -n istio-system kiali-xxx
```

**Error:**
```
Events:
  Type     Reason            Message
  ----     ------            -------
  Warning  FailedScheduling  0/1 nodes are available: 1 Too many pods.
```

**Root Cause:** Single t3.medium node hit pod limit (max ~30 pods including system pods).

**Current pod count:**
```bash
kubectl get pods -A --no-headers | wc -l
# Output: 28
```

Running:
- Kubernetes system pods (~10)
- Istio system pods (~5)
- Application pods (4)
- Argo Rollouts (1)
- Prometheus (1)
- Kiali trying to schedule (failed)

**No room left.**

---

### The Scaling Solution

**Scale nodegroup from 1 → 2:**

Update `infra/main.tf`:

```hcl
managed_node_groups = {
  mission_shadow_ng = {
    name = "mission-shadow-nodes"

    instance_types = ["t3.medium"]
    capacity_type  = "ON_DEMAND"

    min_size     = 2  # Changed from 1
    max_size     = 2  # Changed from 1
    desired_size = 2  # Changed from 1
  }
}
```

**Apply:**
```bash
cd ~/mission-shadow/infra
terraform apply
```

**Wait for new node:**
```bash
kubectl get nodes -w
NAME                        STATUS   ROLES    AGE
ip-10-0-1-71.ec2.internal   Ready    <none>   2d
ip-10-0-2-45.ec2.internal   Ready    <none>   3m  # NEW
```

**Kiali automatically scheduled on new node:**
```bash
kubectl get pods -n istio-system | grep kiali
kiali-6f8d9c7b9f-4x2km   1/1     Running   0          2m15s
```

✅ **Observability stack complete.**

---

### Access Kiali Dashboard

```bash
istioctl dashboard kiali
```

**Opens:** `http://localhost:20001/kiali`

**What you'll see:**
- Graph view: Service topology (shadow-gateway → shadow-payment)
- Applications: shadow-payment with stable/canary versions
- Workloads: Pod status, resource usage
- Services: Traffic metrics, response times
- Istio Config: Gateway, VirtualService, DestinationRule validation

**Screenshot this for Day 7 dossier.**

---

## CANARY DEPLOYMENT — v1 → v2

### Step 1 — Build v2

**Update app version:**

`app/main.py`:
```python
VERSION = "v2"

@app.post("/pay")
async def process_payment(payment: PaymentRequest):
    return {
        "status": "success",
        "transaction_id": transaction_id,
        "amount": payment.amount,
        "currency": payment.currency,
        "source": payment.source,
        "version": VERSION,
        "build": f"{VERSION}-istio-canary",  # NEW
        "message": f"Payment processed via Istio mesh"
    }
```

**Build and push:**
```bash
cd ~/mission-shadow/app
docker build -t mission-shadow:v2 .
docker tag mission-shadow:v2 \
  974066991644.dkr.ecr.us-east-1.amazonaws.com/mission-shadow:v2
docker push 974066991644.dkr.ecr.us-east-1.amazonaws.com/mission-shadow:v2
```

---

### Step 2 — Deploy Canary

```bash
kubectl argo rollouts set image shadow-payment \
  payment-service=974066991644.dkr.ecr.us-east-1.amazonaws.com/mission-shadow:v2
```

---

### Step 3 — Watch Progressive Rollout

```bash
kubectl argo rollouts get rollout shadow-payment --watch
```

**Output:**
```
Name:            shadow-payment
Namespace:       default
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          2/9
  SetWeight:     20
  ActualWeight:  20
Images:          974066991644.dkr.ecr.us-east-1.amazonaws.com/mission-shadow:v1 (stable)
                 974066991644.dkr.ecr.us-east-1.amazonaws.com/mission-shadow:v2 (canary)

NAME                                      KIND        STATUS     AGE  INFO
⟳ shadow-payment                          Rollout     ॥ Paused   2d   
├──# revision:2 (canary)                                               
│  └──⧉ shadow-payment-7d9f8b6c4d         ReplicaSet  ✔ Healthy  2m   canary,delay:29s
│     └──□ shadow-payment-7d9f8b6c4d-x7k9m Pod         ✔ Running  2m   ready:2/2
└──# revision:1 (stable)                                               
   └──⧉ shadow-payment-5748fc7c9f         ReplicaSet  ✔ Healthy  2d   stable
      ├──□ shadow-payment-5748fc7c9f-25kt4 Pod         ✔ Running  2d   ready:2/2
      ├──□ shadow-payment-5748fc7c9f-2fg7l Pod         ✔ Running  2d   ready:2/2
      ├──□ shadow-payment-5748fc7c9f-dk74s Pod         ✔ Running  2d   ready:2/2
      └──□ shadow-payment-5748fc7c9f-dwjgm Pod         ✔ Running  2d   ready:2/2
```

**Traffic distribution:**
- 20% → v2 canary (1 pod)
- 80% → v1 stable (4 pods)

**Istio VirtualService automatically updated by Argo:**

```bash
kubectl get virtualservice shadow-payment -o yaml
```

**Relevant section:**
```yaml
http:
- name: primary
  route:
  - destination:
      host: shadow-payment-stable
    weight: 80  # Argo updated this
  - destination:
      host: shadow-payment-canary
    weight: 20  # Argo updated this
```

**After 30s, weights automatically shift:**
- Step 3: 40% canary, 60% stable
- Step 4: 60% canary, 40% stable
- Step 5: 80% canary, 20% stable
- Step 6: 100% canary, 0% stable (full promotion)

---

### Step 4 — Verify Traffic Splitting

**Get ingress gateway external IP:**

```bash
export GATEWAY_URL=$(kubectl get svc istio-ingressgateway -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo $GATEWAY_URL
# Output: a3f5e8d7c....elb.us-east-1.amazonaws.com
```

**Test weighted routing:**

```bash
for i in {1..20}; do
  curl -s http://$GATEWAY_URL/pay \
    -H "Content-Type: application/json" \
    -d '{"amount": 100, "currency": "USD", "source": "test"}' \
    | jq -r '.version'
done | sort | uniq -c
```

**Output (at 20% canary weight):**
```
  16 v1
   4 v2
```

**Perfect 80/20 split.** Istio traffic routing working as expected.

---

### The "Empty Reply from Server" Debugging

**Problem encountered mid-deployment:**

```bash
curl http://$GATEWAY_URL/pay
curl: (52) Empty reply from server
```

**Root Cause #1 — Gateway not attached to VirtualService:**

Checked VirtualService:
```bash
kubectl get virtualservice shadow-payment -o yaml
```

Missing `gateways` field. Added:
```yaml
spec:
  gateways:
  - shadow-gateway  # CRITICAL
  hosts:
  - "*"
```

**Root Cause #2 — Service endpoints missing:**

```bash
kubectl get endpoints shadow-payment-stable
NAME                     ENDPOINTS
shadow-payment-stable    <none>
```

**Why:** Service selector had wrong `rollouts-pod-template-hash`.

**Fix:** Updated services.yaml with correct ReplicaSet hashes.

**Root Cause #3 — Gateway misconfiguration:**

Gateway had wrong selector:
```yaml
selector:
  app: istio-ingressgateway  # WRONG
```

Should be:
```yaml
selector:
  istio: ingressgateway  # CORRECT
```

**After all fixes:**
```bash
curl http://$GATEWAY_URL/pay
{"status": "success", "version": "v1", ...}
```

✅ **Traffic flowing correctly.**

---

## OBSERVABILITY VALIDATION

### Kiali Dashboard Views

**Access:**
```bash
istioctl dashboard kiali
```

**Graph View:**
- Shows `istio-ingressgateway` → `shadow-payment`
- Color-coded traffic flow (green = healthy)
- Request rate, error rate, response time metrics
- Live traffic animation

**Applications View:**
- shadow-payment app
- Both versions (v1 stable, v2 canary) visible
- Traffic distribution percentages shown

**Workloads View:**
- Individual pod metrics
- CPU, memory usage per pod
- Request throughput per pod

**Services View:**
- shadow-payment service
- Inbound/outbound traffic rates
- P50, P95, P99 latency metrics

---

### Prometheus Metrics

**Access:**
```bash
kubectl port-forward -n istio-system svc/prometheus 9090:9090 &
```

**Open:** `http://localhost:9090`

**Key queries:**

**Request rate:**
```promql
sum(rate(istio_requests_total{destination_service="shadow-payment.default.svc.cluster.local"}[1m]))
```

**Success rate:**
```promql
sum(rate(istio_requests_total{destination_service="shadow-payment.default.svc.cluster.local",response_code="200"}[1m])) 
/ 
sum(rate(istio_requests_total{destination_service="shadow-payment.default.svc.cluster.local"}[1m]))
```

**P95 latency:**
```promql
histogram_quantile(0.95, 
  sum(rate(istio_request_duration_milliseconds_bucket{destination_service="shadow-payment.default.svc.cluster.local"}[1m])) by (le)
)
```

**These metrics will power Day 6 automated rollback.**

---

## INFRASTRUCTURE COST UPDATE

**New resources:**
- EKS control plane: $0.10/hr
- 2x t3.medium nodes: $0.08/hr (2 × $0.04)
- 2x Classic ELB (K8s + Istio ingress): $0.05/hr (2 × $0.025)
- **Total: ~$0.23/hr** (~$5.52/day)

**Budget impact:**
- 7 days × $5.52 = **$38.64**
- Remaining budget: $118 - $38.64 = **$79.36**
- Still safe, but tighter margins for mistakes

**Nightly cleanup now critical:**
```bash
kubectl delete svc shadow-payment -n default
kubectl delete svc istio-ingressgateway -n istio-system
sleep 120
cd ~/mission-shadow/infra
terraform destroy
```

---

## LESSONS LEARNED

### 1. Webhook Timeouts Are Infrastructure Issues

When sidecar injection webhook times out, it's usually:
- `istiod` overloaded or crashed
- Network policy blocking webhook traffic
- ValidatingWebhookConfiguration misconfigured

**Fix:** Restart `istiod`, verify webhook service endpoints, check network policies.

---

### 2. Ingress Gateway Needs Proper Bootstrap

Handcrafted ingress deployments fail because they lack:
- Root certificates from istiod
- xDS server configuration
- SDS (Secret Discovery Service) setup

**Fix:** Always use `istioctl install` to create ingress with proper config.

---

### 3. VirtualService Requires Gateway Attachment

A VirtualService without a `gateways` field only handles internal mesh traffic.

**For external traffic:** Must specify `gateways: [shadow-gateway]`

---

### 4. Service Selector Labels Must Match

Kubernetes services select pods by labels. Argo Rollouts adds `rollouts-pod-template-hash` dynamically.

**You must:**
1. Get current ReplicaSet hash: `kubectl get rs`
2. Update service selector with exact hash
3. Re-apply when new ReplicaSets are created

---

### 5. Node Limits Are Real

Single t3.medium node = ~30 pod limit (AWS ENI constraints).

**When adding observability tools:** Scale horizontally, not vertically.

---

### 6. Istio + Argo Integration Requires 3 Services

- **Root service** (`shadow-payment`) — mesh discovery
- **Stable service** (`shadow-payment-stable`) — stable pods only
- **Canary service** (`shadow-payment-canary`) — canary pods only

Without all three, Argo Rollout becomes `Degraded`.

---

## CURRENT STATE

**Cluster Status:** ✅ Running (2x t3.medium nodes)  
**Istio:** ✅ Installed (istiod + ingress gateway)  
**Argo Rollouts:** ✅ Integrated with Istio traffic routing  
**Payment Service:** ✅ v2 deployed via canary, weighted traffic splitting live  
**Observability:** ✅ Kiali + Prometheus operational  

**Files Created:**
- `k8s/istio-gateway.yaml` — Gateway configuration
- `k8s/services.yaml` — Root + stable + canary services
- `k8s/virtualservice.yaml` — Traffic routing rules
- `k8s/destinationrule.yaml` — Subset definitions
- `k8s/rollout.yaml` — Updated with Istio integration

**Images in ECR:**
- `mission-shadow:v1` — Stable baseline
- `mission-shadow:v2` — First Istio-managed canary
- `mission-shadow:v3` — (Day 4 image, superseded)

---

## WHAT'S NEXT — DAY 6

**Mission:** Automated Rollback + Chaos Engineering

**Objective:** Build a self-healing system that detects bad deployments and rolls back automatically — without human intervention.

---

### Phase 1: Metrics Collection (30 min)

**Install Prometheus ServiceMonitor for custom app metrics:**

Update `app/main.py` to expose Prometheus metrics:

```python
from prometheus_client import Counter, Histogram, generate_latest
from fastapi.responses import Response
import time

# Metrics
request_count = Counter(
    'payment_requests_total', 
    'Total payment requests', 
    ['version', 'status']
)

request_duration = Histogram(
    'payment_duration_seconds', 
    'Payment request duration', 
    ['version']
)

error_count = Counter(
    'payment_errors_total',
    'Total payment errors',
    ['version', 'error_type']
)

@app.post("/pay")
async def process_payment(payment: PaymentRequest):
    start_time = time.time()
    
    try:
        # ... existing payment logic ...
        request_count.labels(version=VERSION, status='success').inc()
        return response
    except Exception as e:
        request_count.labels(version=VERSION, status='error').inc()
        error_count.labels(version=VERSION, error_type=type(e).__name__).inc()
        raise
    finally:
        duration = time.time() - start_time
        request_duration.labels(version=VERSION).observe(duration)

@app.get("/metrics")
async def metrics():
    """Prometheus scrape endpoint"""
    return Response(content=generate_latest(), media_type="text/plain")
```

**Update requirements.txt:**
```txt
fastapi==0.115.0
uvicorn==0.32.0
pydantic==2.9.0
prometheus-client==0.21.0
```

**Rebuild as v3:**
```bash
docker build -t mission-shadow:v3 .
docker push 974066991644.dkr.ecr.us-east-1.amazonaws.com/mission-shadow:v3

kubectl argo rollouts set image shadow-payment \
  payment-service=974066991644.dkr.ecr.us-east-1.amazonaws.com/mission-shadow:v3
```

---

**Create ServiceMonitor:**

`k8s/servicemonitor.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: shadow-payment-metrics
  labels:
    app: shadow-payment
spec:
  selector:
    app: shadow-payment
  ports:
  - name: metrics
    port: 8000
    targetPort: 8000
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: shadow-payment
  namespace: default
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app: shadow-payment
  endpoints:
  - port: metrics
    path: /metrics
    interval: 15s
```

**Apply:**
```bash
kubectl apply -f k8s/servicemonitor.yaml
```

**Verify in Prometheus:**
```bash
kubectl port-forward -n istio-system svc/prometheus 9090:9090 &
```

Open `http://localhost:9090/targets` — should see `shadow-payment` endpoint.

Query:
```promql
payment_requests_total
```

Should return data.

---

### Phase 2: Define SLI Thresholds (20 min)

**Service Level Indicators (SLIs):**

1. **Error Rate:** <1% (99% success rate)
2. **P95 Latency:** <300ms
3. **Request Rate:** >0 (service is receiving traffic)

**These become our automated rollback triggers.**

---

### Phase 3: Create Argo AnalysisTemplates (45 min)

**AnalysisTemplate #1 — Success Rate**

`k8s/analysis-success-rate.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
  namespace: default
spec:
  metrics:
  - name: success-rate
    interval: 30s
    count: 5
    successCondition: result >= 0.99
    failureLimit: 2
    provider:
      prometheus:
        address: http://prometheus.istio-system.svc.cluster.local:9090
        query: |
          sum(rate(payment_requests_total{status="success"}[1m])) 
          / 
          sum(rate(payment_requests_total[1m]))
```

**What this does:**
- Queries Prometheus every 30s
- Checks if success rate ≥ 99%
- If it drops below 99% for **2 consecutive checks** → rollback
- Runs for 5 iterations total (2.5 minutes)

---

**AnalysisTemplate #2 — P95 Latency**

`k8s/analysis-latency.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: latency-check
  namespace: default
spec:
  metrics:
  - name: p95-latency
    interval: 30s
    count: 5
    successCondition: result < 0.3
    failureLimit: 2
    provider:
      prometheus:
        address: http://prometheus.istio-system.svc.cluster.local:9090
        query: |
          histogram_quantile(0.95, 
            sum(rate(payment_duration_seconds_bucket[1m])) by (le)
          )
```

**Triggers rollback if P95 latency exceeds 300ms.**

---

**Apply both:**
```bash
kubectl apply -f k8s/analysis-success-rate.yaml
kubectl apply -f k8s/analysis-latency.yaml
```

---

### Phase 4: Integrate Analysis into Rollout (15 min)

**Update `k8s/rollout.yaml`:**

```yaml
spec:
  strategy:
    canary:
      stableService: shadow-payment-stable
      canaryService: shadow-payment-canary
      trafficRouting:
        istio:
          virtualService:
            name: shadow-payment
            routes:
            - primary
      analysis:
        templates:
        - templateName: success-rate
        - templateName: latency-check
        startingStep: 2  # Start analysis after first canary step
        args:
        - name: service-name
          value: shadow-payment
      steps:
      - setWeight: 20
      - pause: {duration: 30s}
      - setWeight: 40
      - pause: {duration: 60s}  # Analysis runs here
      - setWeight: 60
      - pause: {duration: 60s}  # And here
      - setWeight: 80
      - pause: {duration: 60s}  # And here
      - setWeight: 100
```

**Apply:**
```bash
kubectl apply -f k8s/rollout.yaml
```

---

### Phase 5: Build Broken v4 for Chaos Testing (30 min)

**Create a version that intentionally fails SLIs:**

`app/main.py` (v4):
```python
import random
import time

VERSION = "v4"

@app.post("/pay")
async def process_payment(payment: PaymentRequest):
    start_time = time.time()
    
    # CHAOS: 30% requests fail with 500 error
    if random.random() < 0.30:
        request_count.labels(version=VERSION, status='error').inc()
        error_count.labels(version=VERSION, error_type='InternalServerError').inc()
        raise HTTPException(status_code=500, detail="Payment processor unavailable")
    
    # CHAOS: 20% requests have 500ms latency
    if random.random() < 0.20:
        time.sleep(0.5)
    
    transaction_id = f"txn_{int(time.time() * 1000)}"
    
    response = {
        "status": "success",
        "transaction_id": transaction_id,
        "amount": payment.amount,
        "currency": payment.currency,
        "source": payment.source,
        "version": VERSION,
        "build": f"{VERSION}-chaos",
        "message": f"Payment processed (chaos mode)"
    }
    
    request_count.labels(version=VERSION, status='success').inc()
    duration = time.time() - start_time
    request_duration.labels(version=VERSION).observe(duration)
    
    return response
```

**Build and push:**
```bash
docker build -t mission-shadow:v4 .
docker push 974066991644.dkr.ecr.us-east-1.amazonaws.com/mission-shadow:v4
```

---

### Phase 6: Deploy v4 and Watch Automated Rollback (30 min)

**Deploy the broken canary:**

```bash
kubectl argo rollouts set image shadow-payment \
  payment-service=974066991644.dkr.ecr.us-east-1.amazonaws.com/mission-shadow:v4
```

**Watch in real-time:**

Terminal 1:
```bash
kubectl argo rollouts get rollout shadow-payment --watch
```

Terminal 2:
```bash
kubectl get analysisrun -w
```

Terminal 3 (generate load to trigger metrics):
```bash
while true; do
  curl -s http://$GATEWAY_URL/pay \
    -H "Content-Type: application/json" \
    -d '{"amount": 100, "currency": "USD", "source": "loadtest"}' \
    > /dev/null
  sleep 0.1
done
```

**Expected behavior:**

1. v4 canary deploys (20% traffic)
2. Load generator sends requests
3. 30% of v4 requests return 500 errors
4. Success rate drops to ~85% (below 99% threshold)
5. AnalysisRun detects failure after 2 consecutive checks (~60s)
6. **Argo Rollouts automatically aborts canary**
7. Traffic rolls back to 100% stable v3
8. System self-healed — no human intervention

**Check AnalysisRun status:**
```bash
kubectl get analysisrun
NAME                               STATUS   AGE
shadow-payment-7d9f8b6c4d-2-1      Failed   3m
```

**Check rollout events:**
```bash
kubectl describe rollout shadow-payment
```

**Should see:**
```
Events:
  Type     Reason              Message
  ----     ------              -------
  Normal   RolloutUpdated      Rollout updated to revision 4
  Normal   AnalysisRunCreated  Created AnalysisRun shadow-payment-xxx
  Warning  AnalysisRunFailed   AnalysisRun shadow-payment-xxx failed
  Normal   RolloutAborted      Rollout aborted, rolling back to stable
  Normal   SetWeight           Set weight to 0 (canary), 100 (stable)
```

✅ **Automated rollback successful.**

---

### Phase 7: Additional Chaos Experiments (1 hour)

**Experiment 1 — Pod Kill (Resilience Test)**

Kill a stable pod during traffic:
```bash
kubectl delete pod -l app=shadow-payment,rollouts-pod-template-hash=<stable-hash> --force --grace-period=0
```

**Expected:** Kubernetes recreates pod, Istio routes traffic to remaining healthy pods, zero downtime.

---

**Experiment 2 — CPU Stress (Resource Exhaustion)**

Install stress tool in a pod:
```bash
kubectl exec -it <pod-name> -- sh
apk add stress-ng
stress-ng --cpu 1 --timeout 120s
```

**Expected:** Pod CPU hits limit, throttled, latency increases, analysis might trigger rollback if P95 > 300ms.

---

**Experiment 3 — Network Delay (Istio Fault Injection)**

Add delay to VirtualService:

```yaml
spec:
  http:
  - fault:
      delay:
        percentage:
          value: 50
        fixedDelay: 2s
    route:
    - destination:
        host: shadow-payment-canary
      weight: 20
```

**Apply and watch latency analysis fail.**

---

**Experiment 4 — Complete Service Failure**

Deploy v5 that crashes on startup:

```python
@app.on_event("startup")
async def startup_event():
    raise Exception("Database connection failed")
```

**Expected:** Pod enters CrashLoopBackOff, canary never becomes healthy, rollout stuck at step 1, stable keeps serving.

---

### Phase 8: Grafana Dashboard (Optional, 1 hour)

**Install Grafana:**
```bash
kubectl apply -f ~/istio-1.22.0/samples/addons/grafana.yaml
```

**Access:**
```bash
istioctl dashboard grafana
```

**Create custom dashboard:**
- Panel 1: Request rate (line graph)
- Panel 2: Success rate (gauge, red if <99%)
- Panel 3: P95 latency (line graph, threshold at 300ms)
- Panel 4: Canary vs stable traffic distribution
- Panel 5: Error rate by version

**Export as JSON, include in final dossier.**

---

## DAY 6 DELIVERABLES

At the end of Day 6, you should have:

1. ✅ Prometheus metrics instrumented in application
2. ✅ ServiceMonitor scraping app metrics
3. ✅ AnalysisTemplates for success rate + latency
4. ✅ Rollout integrated with automated analysis
5. ✅ Broken v4 deployed and auto-rolled back
6. ✅ Multiple chaos experiments documented
7. ✅ Screenshots of:
   - Kiali showing rollback
   - AnalysisRun failure
   - Prometheus query results
   - Grafana dashboard (optional)

---

## DAY 6 TIMELINE

| Phase | Task | Duration |
|-------|------|----------|
| 1 | Add Prometheus metrics to app | 30 min |
| 2 | Define SLI thresholds | 20 min |
| 3 | Create AnalysisTemplates | 45 min |
| 4 | Update Rollout config | 15 min |
| 5 | Build broken v4 | 30 min |
| 6 | Deploy + watch auto-rollback | 30 min |
| 7 | Additional chaos tests | 60 min |
| 8 | (Optional) Grafana dashboard | 60 min |
| **TOTAL** | | **~4 hours** |

---

## DAY 7 PREVIEW — FINAL MISSION

**Objective:** Documentation, cleanup, and final dossier

**Tasks:**
1. Final chaos demonstration with video/screenshots
2. Create architecture diagrams (draw.io or Lucidchart)
3. Write comprehensive README.md with:
   - Project overview
   - Architecture explanation
   - Setup instructions
   - Key learnings
4. Organize GitHub repo:
   - `/app` — Application code
   - `/infra` — Terraform files
   - `/k8s` — All Kubernetes manifests
   - `/docs` — Handover docs, diagrams
   - `/screenshots` — Kiali, Grafana, rollback evidence
5. **FINAL DESTROY:**
   ```bash
   kubectl delete svc --all -n default
   kubectl delete svc --all -n istio-system
   sleep 120
   cd ~/mission-shadow/infra
   terraform destroy -auto-approve
   ```
6. Final cost audit
7. Submit project

---

## CLEANUP SCRIPT — CRITICAL

**File:** `infra/cleanup.sh`

```bash
#!/bin/bash
set -e

echo "========================================"
echo "MISSION SHADOW — NIGHTLY CLEANUP"
echo "========================================"

echo "Step 1: Deleting Kubernetes LoadBalancer services..."
kubectl delete svc shadow-payment -n default --ignore-not-found=true
kubectl delete svc istio-ingressgateway -n istio-system --ignore-not-found=true

echo "Step 2: Waiting for AWS ELB cleanup (120s)..."
sleep 120

echo "Step 3: Running Terraform destroy..."
cd "$(dirname "$0")"
terraform destroy -auto-approve

echo "Step 4: Cleanup complete. Cluster destroyed."
echo "========================================"
echo "Estimated savings: ~$5.52/day"
echo "========================================"
```

**Make executable:**
```bash
chmod +x infra/cleanup.sh
```

**Daily usage:**
```bash
./infra/cleanup.sh
```

---

## TROUBLESHOOTING REFERENCE

**AnalysisRun stuck in "Running":**
```bash
kubectl logs -n argo-rollouts deployment/argo-rollouts
kubectl describe analysisrun <name>
```

**Prometheus not scraping metrics:**
```bash
kubectl port-forward -n istio-system svc/prometheus 9090:9090
# Check http://localhost:9090/targets
```

**Rollout not starting analysis:**
```bash
kubectl describe rollout shadow-payment
# Check events for AnalysisRun creation
```

**Canary not rolling back despite bad metrics:**
```bash
kubectl get analysisrun
kubectl logs analysisrun/<name>
# Verify Prometheus query returns data
```

---

## FINAL NOTES

Day 5 was the **integration boss fight**. Every layer broke:
- Webhook timeouts blocking pod creation
- Ingress gateway crashing due to missing certs
- Empty server replies from misconfigured routing
- Pod scheduling failures hitting node limits
- Argo degradation from missing services

**But we won.** Istio + Argo Rollouts now working seamlessly. Weighted traffic splitting live. Observability operational.

Tomorrow = automated rollback. Shadow proves it can heal itself.

**Two days left. Let's finish this.**

---

*This handover document lives at: `~/mission-shadow/docs/DAY5_HANDOVER.md`*
