#!/bin/bash

# Exit on any error
set -e
sleep 10
exec > >(tee /var/log/k8s-bootstrap.log | logger -t bootstrap -s) 2>&1

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
    echo "Please run this script as root, e.g. sudo ./k8s-setup-master.sh"
    exit 1
fi

# Disable swap (required for Kubernetes)
swapoff -a
sed -i '/swap/d' /etc/fstab

# Configure kernel modules for Kubernetes networking
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Set sysctl parameters required for Kubernetes networking
cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# Update package repositories
apt update
apt-get update

# Install dependencies
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

# Add Kubernetes apt repository
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

apt-get update

# Install containerd
apt-get install -y containerd

# Configure containerd to use systemd cgroups
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

# Install Kubernetes components
VERSION=1.32.7-1.1
apt-get update
apt-get install -y kubelet=$VERSION kubeadm=$VERSION kubectl=$VERSION
apt-mark hold kubelet kubeadm kubectl

# Print Kubernetes versions
kubeadm version
kubelet --version
kubectl version --client

systemctl restart kubelet.service
systemctl enable kubelet.service

# Pre-pull Kubernetes images to save time during init
kubeadm config images pull

# Initialize the Kubernetes master node
echo "[BOOTSTRAP] Running kubeadm init..."
kubeadm init --pod-network-cidr=10.244.0.0/16

# Set up kubeconfig for non-root user
REAL_USER=${SUDO_USER:-ubuntu}
USER_HOME=$(eval echo "~$REAL_USER")

mkdir -p "$USER_HOME/.kube"
cp /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
chown -R "$REAL_USER:$REAL_USER" "$USER_HOME/.kube"

export KUBECONFIG="$USER_HOME/.kube/config"

# DNS FIX: replace systemd stub resolver with VPC DNS and public fallback
echo "Configuring resolv.conf with AWS VPC DNS and Google fallback..."
systemctl disable systemd-resolved
systemctl stop systemd-resolved
rm -f /etc/resolv.conf
cat <<EOF > /etc/resolv.conf
nameserver 172.31.0.2
nameserver 8.8.8.8
EOF

# Wait for kube-apiserver to become reachable
until kubectl version >/dev/null 2>&1; do
    echo "Waiting for API server..."
    sleep 5
done

# Install Flannel network plugin
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml

# Wait for CoreDNS to be scheduled
echo "Waiting for CoreDNS..."
until kubectl get pods -n kube-system | grep coredns | grep -q Running; do
    kubectl get pods -n kube-system
    sleep 5
done

# Deploy a test nginx pod
kubectl run testpod --image=nginx --restart=Never

# Wait for the pod to exist
while ! kubectl get pod testpod 2>/dev/null | grep -q Running; do
  echo "Waiting for testpod to be running..."
  sleep 5
done

# Delete old service if it exists
kubectl delete svc testpod-service --ignore-not-found

# Create NodePort service if it doesn't exist
if ! kubectl get svc nginx-nodeport > /dev/null 2>&1; then
  kubectl expose pod testpod --type=NodePort --port=80 --name=nginx-nodeport
fi

sleep 5
apt-get install -y unzip
sleep 10

# Install Helm 
echo "[BOOTSTRAP] Installing Helm..." | tee -a /var/log/k8s-bootstrap.log
cd /tmp
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh >> /var/log/k8s-bootstrap.log 2>&1
rm -f get_helm.sh
helm version >> /var/log/k8s-bootstrap.log 2>&1 || echo "[WARN] Helm version check failed" >> /var/log/k8s-bootstrap.log

# Add Traefik Helm repo and prepare namespace
echo "[BOOTSTRAP] Adding Traefik Helm repo..." | tee -a /var/log/k8s-bootstrap.log
helm repo add traefik https://traefik.github.io/charts >> /var/log/k8s-bootstrap.log 2>&1
helm repo update >> /var/log/k8s-bootstrap.log 2>&1
kubectl get namespace traefik >/dev/null 2>&1 || kubectl create namespace traefik

# Install Traefik via Helm using NodePort
echo "[BOOTSTRAP] Installing Traefik ingress controller..." | tee -a /var/log/k8s-bootstrap.log

helm install traefik traefik/traefik \
  --namespace traefik \
  --set service.type=NodePort \
  --set service.spec.externalTrafficPolicy=Cluster \
  --set service.nodePorts.http=32080 \
  --set service.nodePorts.https=32443 \
  --set ports.web.nodePort=32080 \
  --set ports.websecure.nodePort=32443 \
  --set ingressClass.enabled=true \
  --set ingressClass.isDefaultClass=true

# Apply Ingress definition for Tripfinder
kubectl apply -f https://raw.githubusercontent.com/pmcann/Linux-Scripts/main/k8s-tripfinder/tripfinder-ingress.yaml

# Install kube-prometheus-stack

echo "[BOOTSTRAP] Installing Prometheus + Grafana stack..." | tee -a /var/log/k8s-bootstrap.log
kubectl get namespace monitoring >/dev/null 2>&1 || kubectl create namespace monitoring
curl -s -o /tmp/values.yaml https://raw.githubusercontent.com/pmcann/Linux-Scripts/main/k8s-monitoring/values.yaml
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >> /var/log/k8s-bootstrap.log 2>&1
helm repo update >> /var/log/k8s-bootstrap.log 2>&1
helm upgrade --install prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f /tmp/values.yaml >> /var/log/k8s-bootstrap.log 2>&1
kubectl apply -f https://raw.githubusercontent.com/pmcann/Linux-Scripts/main/k8s-monitoring/service-monitor-traefik.yaml -n monitoring
kubectl apply -f https://raw.githubusercontent.com/pmcann/Linux-Scripts/main/k8s-monitoring/service-monitor-backend.yaml -n monitoring

# Install AWS CLI v2 (ARM64)
cd /tmp
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install -i /usr/local/aws-cli -b /usr/local/bin
rm -rf aws awscliv2.zip

# Create ECR pull secret for Kubernetes
kubectl create secret docker-registry ecr-secret \
  --docker-server=374965728115.dkr.ecr.us-east-1.amazonaws.com \
  --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password --region us-east-1)" \
  --docker-email=unused@example.com || echo "ECR secret already exists or failed to create"

sleep 3
kubectl apply -f https://raw.githubusercontent.com/pmcann/Linux-Scripts/main/k8s-tripfinder/backend.yaml
kubectl apply -f https://raw.githubusercontent.com/pmcann/Linux-Scripts/main/k8s-tripfinder/frontend.yaml

