#!/bin/bash

# Exit on any error
set -e

echo "🔧 Checking for root privileges..."
if [[ $EUID -ne 0 ]]; then
    echo "❌ Please run this script as root, e.g. sudo ./k8s-setup-master.sh"
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

echo "✅ Kubernetes versions:"
kubeadm version
kubelet --version
kubectl version --client

systemctl restart kubelet.service
systemctl enable kubelet.service

echo "🔧 Pulling Kubernetes images..."
kubeadm config images pull

echo "🔧 Initializing Kubernetes master node..."
kubeadm init

echo "🔧 Setting up kubeconfig for non-root user..."

# Automatically detect the real user
REAL_USER=$(logname)
USER_HOME=$(eval echo "~$REAL_USER")

echo "Detected non-root user: $REAL_USER"
echo "Configuring kubeconfig in $USER_HOME/.kube"

mkdir -p $USER_HOME/.kube
cp -i /etc/kubernetes/admin.conf $USER_HOME/.kube/config
chown $REAL_USER:$REAL_USER $USER_HOME/.kube/config

echo "✅ kubeconfig setup complete for user $REAL_USER"

echo "🔧 Installing Calico network plugin..."
su - $REAL_USER -c "kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml"



echo "✅ Calico installed."

echo "🔧 Checking cluster status..."

su - $REAL_USER -c "kubectl get po -n kube-system"
su - $REAL_USER -c "kubectl get nodes"

echo "🎉 Kubernetes master node setup is complete!"
