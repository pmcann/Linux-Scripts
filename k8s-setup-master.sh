#!/bin/bash

# Exit on any error
set -e

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
apt-get install -y kubelet kubeadm kubectl

# Print Kubernetes versions
kubeadm version
kubelet --version
kubectl version --client

systemctl restart kubelet.service
systemctl enable kubelet.service

# Pre-pull Kubernetes images to save time during init
kubeadm config images pull

# Initialize the Kubernetes master node
sudo kubeadm init --pod-network-cidr=192.168.0.0/16 --v=5

# Set up kubeconfig for non-root user
REAL_USER=${SUDO_USER:-ubuntu}
USER_HOME=$(eval echo "~$REAL_USER")

# Create .kube directory in the user's home
mkdir -p "$USER_HOME/.kube"
cp /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
chown -R "$REAL_USER:$REAL_USER" "$USER_HOME/.kube"

export KUBECONFIG="$USER_HOME/.kube/config"

# Wait for kube-apiserver to become reachable
until kubectl version --short &>/dev/null; do
    sleep 5
done

# Install Calico network plugin
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml

# Check cluster status
kubectl get po -n kube-system
kubectl get nodes

# Deploy a test nginx pod
kubectl run testpod --image=nginx --restart=Never

# Verify test pod status
kubectl get pod testpod
