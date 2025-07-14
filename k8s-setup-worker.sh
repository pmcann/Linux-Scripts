#!/bin/bash

echo "ℹ️chmod +x k8s-setup-worker.sh"
echo "ℹ️sudo ./k8s-setup-worker.sh

# Exit on any error
set -e

echo "🔧 Checking for root privileges..."
if [[ $EUID -ne 0 ]]; then
    echo "❌ Please run this script as root, e.g. sudo ./k8s-setup-worker.sh"
    exit 1
fi

echo "✅ Running as root."

echo "🔧 Disabling swap..."
swapoff -a
sed -i '/swap/d' /etc/fstab

echo "🔧 Configuring kernel modules..."
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

echo "🔧 Setting sysctl parameters..."
cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

echo "✅ Kernel modules and sysctl settings applied."

echo "🔧 Updating apt repositories..."
apt update
apt-get update

echo "🔧 Installing required packages..."
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

echo "🔧 Adding Kubernetes apt repository..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

apt-get update

echo "🔧 Installing containerd..."
apt-get install -y containerd

echo "🔧 Configuring containerd..."
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

echo "🔧 Installing Kubernetes components..."
apt-get install -y kubelet kubeadm kubectl

systemctl enable kubelet
systemctl start kubelet

echo "✅ Kubernetes versions installed:"
kubeadm version
kubelet --version
kubectl version --client

echo "🎯 Worker node setup complete."

echo "ℹ️ To join this node to your cluster, run the join command provided by your master node. For example:"
echo ""
echo "   sudo kubeadm join <MASTER_IP>:6443 --token <TOKEN> \\"
echo "        --discovery-token-ca-cert-hash sha256:<HASH>"
echo ""
echo "✅ Done!"
