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

echo "========================================"
echo "✅ Cleanup complete. Cluster destroyed."
echo "Estimated savings: ~$5.52/day"
echo "========================================"
