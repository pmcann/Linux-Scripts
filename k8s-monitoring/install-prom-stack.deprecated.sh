#!/bin/bash
set -e

echo "[INFO] Creating monitoring namespace..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

echo "[INFO] Adding Prometheus Helm repo..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

echo "[INFO] Installing kube-prometheus-stack with NodePorts..."
helm upgrade --install prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f values.yaml

echo "[INFO] Applying ServiceMonitors..."
kubectl apply -f service-monitor-traefik.yaml -n monitoring
kubectl apply -f service-monitor-backend.yaml -n monitoring

echo "[INFO] Prometheus & Grafana setup complete."
