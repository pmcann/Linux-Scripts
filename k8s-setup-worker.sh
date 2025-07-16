#!/bin/bash

# Exit on any error
set -e

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
    echo "Please run this script as root, e.g. sudo ./k8s-setup-worker.sh"
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

# JOIN THE CLUSTER
# Replace the line below with the join command you get from the master after kubeadm init.
# Example:
# kubeadm join <MASTER_IP>:6443 --token <token> \
#     --discovery-token-ca-cert-hash sha256:<hash>

# kubeadm token create --print-join-command  (run this on the master node)
