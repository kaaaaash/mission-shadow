#!/bin/bash

# ========================================
# MISSION SHADOW — FINAL CLEANUP
# ========================================

set -e

echo "========================================"
echo "MISSION SHADOW — FINAL CLEANUP"
echo "Initiating infrastructure teardown..."
echo "========================================"

echo ""
echo "Step 1: Deleting Kubernetes resources..."

kubectl delete rollout shadow-payment --ignore-not-found=true

kubectl delete svc shadow-payment-stable \
shadow-payment-canary \
--ignore-not-found=true

kubectl delete -f ~/mission-shadow/k8s/istio-traffic.yaml \
--ignore-not-found=true

kubectl delete analysistemplate success-rate \
--ignore-not-found=true

kubectl delete namespace argo-rollouts \
--ignore-not-found=true

kubectl delete namespace istio-system \
--ignore-not-found=true

echo ""
echo "Step 2: Waiting for AWS ELB cleanup..."

for i in {120..1}; do
  printf "\r  Time remaining: %03d seconds" $i
  sleep 1
done

echo ""
echo ""
echo "Step 3: Checking remaining load balancers..."

ELB_COUNT=$(aws elbv2 describe-load-balancers \
  --region us-east-1 \
  --query 'length(LoadBalancers)' \
  --output text 2>/dev/null || echo "0")

echo "  Active Load Balancers: $ELB_COUNT"

if [ "$ELB_COUNT" -gt "0" ]; then
  echo ""
  echo "⚠️  Load balancers still deleting..."
  echo "Waiting extra 60 seconds..."
  sleep 60
fi

echo ""
echo "Step 4: Terraform destroy..."

cd ~/mission-shadow/infra

terraform destroy -auto-approve

echo ""
echo "Step 5: Verifying EKS cluster cleanup..."

CLUSTERS=$(aws eks list-clusters \
  --region us-east-1 \
  --query 'clusters' \
  --output text)

if [ -z "$CLUSTERS" ]; then
  echo "  ✅ No active EKS clusters found"
else
  echo "  ⚠️  Remaining clusters:"
  echo "$CLUSTERS"
fi

echo ""
echo "Step 6: Final cost verification..."

FINAL_ELB_COUNT=$(aws elbv2 describe-load-balancers \
  --region us-east-1 \
  --query 'length(LoadBalancers)' \
  --output text 2>/dev/null || echo "0")

echo "  Remaining Load Balancers: $FINAL_ELB_COUNT"

echo ""
echo "========================================"
echo "✅ MISSION SHADOW DESTROY COMPLETE"
echo "========================================"
echo ""
echo "Operator: kaash"
echo "Status: EXFILTRATED"
echo "Cost burn: STOPPED"
echo ""
echo "Bravo 6 going dark."
echo "========================================"