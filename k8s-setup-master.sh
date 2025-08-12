#!/bin/bash
set -e
sleep 3
exec > >(tee /var/log/k8s-bootstrap.log | logger -t bootstrap -s) 2>&1

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
    echo "Please run this script as root, e.g. sudo ./k8s-setup-master.sh"
    exit 1
fi

# Ensure hostname resolves locally (avoids "unable to resolve host" from sudo)
grep -q "$(hostname)" /etc/hosts || echo "127.0.1.1 $(hostname)" >> /etc/hosts

# ── Clone or update our Git repo ───────────────────────────────────────────────
REPO_URL="https://github.com/pmcann/Linux-Scripts.git"
REPO_DIR="/root/Linux-Scripts"

if [ -d "$REPO_DIR" ]; then
  echo "[BOOTSTRAP] Updating Linux-Scripts..."
  git -C "$REPO_DIR" pull
else
  echo "[BOOTSTRAP] Cloning Linux-Scripts..."
  git clone "$REPO_URL" "$REPO_DIR"
fi

# Make sure all later -f references work
cd "$REPO_DIR"

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
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release unzip

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
systemctl disable systemd-resolved || true
systemctl stop systemd-resolved || true
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

# Delete old service if it exists and create NodePort service for testpod
kubectl delete svc testpod-service --ignore-not-found
if ! kubectl get svc nginx-nodeport >/dev/null 2>&1; then
  kubectl expose pod testpod --type=NodePort --port=80 --name=nginx-nodeport
fi

# ── Install Helm ───────────────────────────────────────────────────────────────
echo "[BOOTSTRAP] Installing Helm..."
cd /tmp
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x get_helm.sh
./get_helm.sh >> /var/log/k8s-bootstrap.log 2>&1
rm -f get_helm.sh
helm version >> /var/log/k8s-bootstrap.log 2>&1 || echo "[WARN] Helm version check failed" >> /var/log/k8s-bootstrap.log

# ── Add Helm repos (incl. EBS CSI) ────────────────────────────────────────────
echo "[BOOTSTRAP] Adding Helm chart repositories..."
helm repo add traefik https://traefik.github.io/charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add jenkinsci https://charts.jenkins.io
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update

# ── Install AWS EBS CSI driver (controller + node plugin) ─────────────────────
echo "[BOOTSTRAP] Installing AWS EBS CSI driver..."
helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system \
  --set controller.serviceAccount.create=true \
  --set controller.serviceAccount.name=ebs-csi-controller-sa

# Create gp3 StorageClass (Retain + WaitForFirstConsumer + expansion)
cat >/tmp/sc-ebs-gp3.yaml <<'YAML'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  fsType: ext4
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
YAML
kubectl apply -f /tmp/sc-ebs-gp3.yaml
kubectl get sc

# ── Install AWS CLI v2 (needed for ECR + SSM + Backup) ────────────────────────
cd /tmp
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o awscliv2.zip
unzip -q awscliv2.zip
./aws/install -i /usr/local/aws-cli -b /usr/local/bin
rm -rf aws awscliv2.zip

# ── Namespaces (idempotent) ───────────────────────────────────────────────────
kubectl create ns jenkins --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns argocd  --dry-run=client -o yaml | kubectl apply -f -

sleep 5

# ── GitHub webhook secret (Jenkins Credentials Provider) from SSM ─────────────
echo "[BOOTSTRAP] Creating/updating GitHub webhook credential in Jenkins..." | tee -a /var/log/k8s-bootstrap.log
SSM_PATH="/tripfinder/github/webhookSecret"
JENKINS_NS="jenkins"
set +e
GH_SECRET_VALUE=$(aws ssm get-parameter --with-decryption --name "$SSM_PATH" --query 'Parameter.Value' --output text 2>/dev/null | tr -d '\n')
if [ -z "$GH_SECRET_VALUE" ] || [ "$GH_SECRET_VALUE" = "None" ]; then
  echo "[WARN] SSM parameter $SSM_PATH not found or empty; skipping webhook secret creation." | tee -a /var/log/k8s-bootstrap.log
else
  kubectl -n "$JENKINS_NS" create secret generic github-webhook-secret \
    --from-literal=text="$GH_SECRET_VALUE" \
    --dry-run=client -o yaml \
  | kubectl label --local -f - jenkins.io/credentials-type=secretText --overwrite -o yaml \
  | kubectl annotate --local -f - \
      jenkins.io/credentials-id=github-webhook-secret \
      jenkins.io/credentials-description="GitHub Webhook Secret" \
      --overwrite -o yaml \
  | kubectl apply -f - >> /var/log/k8s-bootstrap.log 2>&1
fi
set -e

# ── Long-lived secrets from SSM + ECR auth ────────────────────────────────────
ACCOUNT_ID="374965728115"
AWS_REGION="${AWS_REGION:-us-east-1}"
REGION="$AWS_REGION"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

JENKINS_ADMIN_PASSWORD="$(aws ssm get-parameter --with-decryption \
  --name /tripfinder/jenkins/admin_password --query 'Parameter.Value' \
  --output text 2>/dev/null || echo 'ChangeMe!')"

GITHUB_PAT="$(aws ssm get-parameter --with-decryption \
  --name /tripfinder/github/pat --query 'Parameter.Value' \
  --output text 2>/dev/null || echo 'replace-me')"

# Short-lived ECR password (~12h) for bootstrap + image pulls
ECR_PASS="$(aws ecr get-login-password --region "$REGION")"

# ── Secrets used by pods or JCasC (idempotent) ────────────────────────────────
kubectl -n jenkins create secret generic jenkins-admin-secret \
  --from-literal=jenkins-admin-user=admin \
  --from-literal=jenkins-admin-password="$JENKINS_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

# Optional legacy secret
kubectl -n jenkins create secret generic jenkins-github \
  --from-literal=pat="$GITHUB_PAT" \
  --dry-run=client -o yaml | kubectl apply -f -

# Kaniko push auth (dockerconfig) in jenkins ns
kubectl -n jenkins create secret docker-registry ecr-dockercfg \
  --docker-server="${ECR_REGISTRY}" \
  --docker-username=AWS \
  --docker-password="${ECR_PASS}" \
  --docker-email=unused@example.com \
  --dry-run=client -o yaml | kubectl apply -f -

# For Jenkins JCasC credential (id: ecr-creds) if you keep it ENV-based
kubectl -n jenkins create secret generic jenkins-ecr \
  --from-literal=password="$ECR_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

# For workloads pulling from ECR in the default namespace
kubectl -n default create secret docker-registry ecr-secret \
  --docker-server="$ECR_REGISTRY" \
  --docker-username=AWS \
  --docker-password="$ECR_PASS" \
  --docker-email=unused@example.com \
  --dry-run=client -o yaml | kubectl apply -f -

# Make all new pods in default use that pull secret
kubectl -n default patch serviceaccount default --type merge \
  -p '{"imagePullSecrets":[{"name":"ecr-secret"}]}' || true

# ── Ensure jenkins-env Secret for containerEnv ────────────────────────────────
echo "[BOOTSTRAP] Ensuring jenkins-env Secret..." | tee -a /var/log/k8s-bootstrap.log
args=()
[ -n "$GITHUB_PAT" ]            && args+=( --from-literal=GITHUB_TOKEN="$GITHUB_PAT" )
[ -n "$JENKINS_ADMIN_PASSWORD" ]&& args+=( --from-literal=JENKINS_ADMIN_PASSWORD="$JENKINS_ADMIN_PASSWORD" )
[ -n "$ECR_PASS" ]              && args+=( --from-literal=ECR_PASSWORD="$ECR_PASS" )
if [ ${#args[@]} -eq 0 ]; then
  echo "[WARN] No values for jenkins-env; private GitHub indexing may fail." | tee -a /var/log/k8s-bootstrap.log
else
  kubectl -n jenkins create secret generic jenkins-env "${args[@]}" \
    --dry-run=client -o yaml | kubectl apply -f - >> /var/log/k8s-bootstrap.log 2>&1
  echo "[BOOTSTRAP] jenkins-env ensured." | tee -a /var/log/k8s-bootstrap.log
fi

# ── AWS Backup: vault + daily plan + selection-by-tag (idempotent) ────────────
echo "[BOOTSTRAP] Configuring AWS Backup (vault/plan/selection)..."
VAULT="tripfinder-vault"
PLAN_NAME="tripfinder-daily-30d"
SCHEDULE_CRON="cron(30 7 * * ? *)"   # 07:30 UTC = 03:30 ET (summer)
RETENTION_DAYS=30

# Ensure service-linked role exists
aws iam create-service-linked-role --aws-service-name backup.amazonaws.com >/dev/null 2>&1 || true

# Create vault if missing
if ! aws backup list-backup-vaults --query "BackupVaultList[?BackupVaultName=='${VAULT}'] | [0].BackupVaultName" --output text 2>/dev/null | grep -q "${VAULT}"; then
  aws backup create-backup-vault --backup-vault-name "${VAULT}" || true
  echo "[BOOTSTRAP] Created backup vault: ${VAULT}"
else
  echo "[BOOTSTRAP] Backup vault exists: ${VAULT}"
fi

# Find or create plan
PLAN_ID=$(aws backup list-backup-plans --query "BackupPlansList[?BackupPlanName=='${PLAN_NAME}'] | [0].BackupPlanId" --output text 2>/dev/null)
if [[ -z "$PLAN_ID" || "$PLAN_ID" == "None" ]]; then
  cat >/tmp/plan-30d.json <<EOF
{
  "BackupPlanName": "${PLAN_NAME}",
  "Rules": [
    {
      "RuleName": "daily-0730utc",
      "TargetBackupVaultName": "${VAULT}",
      "ScheduleExpression": "${SCHEDULE_CRON}",
      "StartWindowMinutes": 60,
      "CompletionWindowMinutes": 180,
      "Lifecycle": { "DeleteAfterDays": ${RETENTION_DAYS} }
    }
  ]
}
EOF
  PLAN_ID=$(aws backup create-backup-plan --backup-plan file:///tmp/plan-30d.json --query BackupPlanId --output text)
  echo "[BOOTSTRAP] Created backup plan: ${PLAN_NAME} (${PLAN_ID})"
else
  echo "[BOOTSTRAP] Backup plan exists: ${PLAN_NAME} (${PLAN_ID})"
fi

# Use the service-linked role for selections
SLR_ARN=$(aws iam get-role --role-name AWSServiceRoleForBackup --query Role.Arn --output text 2>/dev/null || true)

# Create tag-based selection if missing
if [[ -n "$PLAN_ID" && -n "$SLR_ARN" ]]; then
  SEL_COUNT=$(aws backup list-backup-selections --backup-plan-id "$PLAN_ID" \
    --query "length(BackupSelectionsList[?SelectionName=='tag-backup-tripfinder'])" --output text 2>/dev/null || echo 0)
  if [[ "$SEL_COUNT" == "0" || "$SEL_COUNT" == "None" ]]; then
    cat >/tmp/selection.json <<EOF
{
  "SelectionName": "tag-backup-tripfinder",
  "IamRoleArn": "${SLR_ARN}",
  "ListOfTags": [
    { "ConditionType": "STRINGEQUALS", "ConditionKey": "backup", "ConditionValue": "tripfinder" }
  ]
}
EOF
    aws backup create-backup-selection --backup-plan-id "$PLAN_ID" --backup-selection file:///tmp/selection.json >/dev/null
    echo "[BOOTSTRAP] Created backup selection 'tag-backup-tripfinder' on plan ${PLAN_NAME}"
  else
    echo "[BOOTSTRAP] Backup selection 'tag-backup-tripfinder' already present."
  fi
else
  echo "[BOOTSTRAP][WARN] Could not resolve plan id or service-linked role; skipping selection creation."
fi

# Auto-tag PV volumes hourly so they're protected by the plan
install -m 0755 /dev/stdin /usr/local/bin/tag-pv-volumes.sh <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
LOG="/var/log/tag-pv-volumes.log"
VOL_IDS=$(kubectl get pv -o jsonpath='{range .items[*]}{.spec.csi.volumeHandle}{"\n"}{end}' 2>/dev/null | grep '^vol-' || true)
if [ -z "$VOL_IDS" ]; then
  echo "$(date -Is) no PV-backed volumes found" >> "$LOG"
  exit 0
fi
for VOL in $VOL_IDS; do
  if aws ec2 create-tags --resources "$VOL" --tags Key=backup,Value=tripfinder >/dev/null 2>&1; then
    echo "$(date -Is) tagged $VOL backup=tripfinder" >> "$LOG"
  else
    echo "$(date -Is) WARN: failed to tag $VOL (missing ec2:CreateTags?)" >> "$LOG"
  fi
done
EOS
( crontab -l 2>/dev/null; echo "17 * * * * /usr/local/bin/tag-pv-volumes.sh" ) | crontab -
echo "[BOOTSTRAP] Installed cron to tag PV volumes hourly."

# ── Install Traefik ───────────────────────────────────────────────────────────
echo "[BOOTSTRAP] Installing Traefik ingress controller..."
kubectl get namespace traefik >/dev/null 2>&1 || kubectl create namespace traefik
helm upgrade --install traefik traefik/traefik \
  --namespace traefik \
  --set service.type=NodePort \
  --set service.spec.externalTrafficPolicy=Cluster \
  --set service.nodePorts.http=32080 \
  --set service.nodePorts.https=32443 \
  --set ports.web.nodePort=32080 \
  --set ports.websecure.nodePort=32443 \
  --set ingressClass.enabled=true \
  --set ingressClass.isDefaultClass=true

# ── RBAC: allow Jenkins to read Secrets for creds provider (before Jenkins starts) ──
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: jenkins-credentials-read
  namespace: jenkins
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get","list","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jenkins-credentials-read
  namespace: jenkins
subjects:
- kind: ServiceAccount
  name: jenkins
  namespace: jenkins
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: jenkins-credentials-read
EOF

# ── Install Jenkins with retry (still ephemeral; PVC enable comes later) ──────
echo "[BOOTSTRAP] Installing Jenkins..." | tee -a /var/log/k8s-bootstrap.log
kubectl create ns jenkins --dry-run=client -o yaml | kubectl apply -f - >/dev/null

HELM_ARGS=(
  upgrade --install jenkins jenkinsci/jenkins
  -n jenkins
  -f "$REPO_DIR/k8s-helm/jenkins/values.yaml"
  -f "$REPO_DIR/k8s-helm/jenkins/values-kubecloud.yaml"
  --set controller.serviceType=NodePort
  --set controller.servicePort=8080
  --set controller.nodePort=32010
  --set persistence.enabled=false
  --wait --timeout 10m
)

max=6
for i in $(seq 1 $max); do
  helm repo add jenkinsci https://charts.jenkins.io >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true

  if helm "${HELM_ARGS[@]}" >> /var/log/k8s-bootstrap.log 2>&1; then
    echo "[BOOTSTRAP] Jenkins chart installed." | tee -a /var/log/k8s-bootstrap.log
    break
  fi

  if [ "$i" -lt "$max" ]; then
    sleep_sec=$((i * 15))
    echo "[WARN] Jenkins Helm install failed (attempt $i/$max). Retrying in ${sleep_sec}s..." | tee -a /var/log/k8s-bootstrap.log
    sleep "$sleep_sec"
  else
    echo "[ERROR] Jenkins Helm install failed after $max attempts." | tee -a /var/log/k8s-bootstrap.log
    exit 1
  fi
done

kubectl -n jenkins rollout status statefulset/jenkins

# ── ngrok tunnel for Jenkins (from SSM) ───────────────────────────────────────
NGROK_AUTHTOKEN="$(aws ssm get-parameter --with-decryption \
  --name /tripfinder/ngrok/authtoken --query 'Parameter.Value' --output text 2>/dev/null || true)"
NGROK_DOMAIN="$(aws ssm get-parameter \
  --name /tripfinder/ngrok/domain --query 'Parameter.Value' --output text 2>/dev/null || true)"

if [ -n "$NGROK_AUTHTOKEN" ] && [ -n "$NGROK_DOMAIN" ] && [ -f "$REPO_DIR/k8s-tripfinder/ngrok-jenkins.yaml" ]; then
  echo "[BOOTSTRAP] Creating ngrok Secret and applying tunnel..."
  kubectl -n jenkins create secret generic ngrok-secret \
    --from-literal=NGROK_AUTHTOKEN="$NGROK_AUTHTOKEN" \
    --from-literal=NGROK_DOMAIN="$NGROK_DOMAIN" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n jenkins apply -f "$REPO_DIR/k8s-tripfinder/ngrok-jenkins.yaml"
else
  echo "[BOOTSTRAP][WARN] ngrok params or manifest missing; skipping tunnel."
fi

# --- RBAC: allow Jenkins to run agent Pods in 'jenkins' ns ---
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jenkins-agents
  namespace: jenkins
subjects:
- kind: ServiceAccount
  name: jenkins
  namespace: jenkins
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: edit
EOF

# ── Install Prometheus + Grafana ──────────────────────────────────────────────
echo "[BOOTSTRAP] Installing Prometheus + Grafana stack..."
kubectl get namespace monitoring >/dev/null 2>&1 || kubectl create namespace monitoring
helm upgrade --install prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f "$REPO_DIR/k8s-monitoring/values.yaml"

kubectl apply -f "$REPO_DIR/k8s-monitoring/service-monitor-traefik.yaml" -n monitoring
kubectl apply -f "$REPO_DIR/k8s-monitoring/service-monitor-backend.yaml" -n monitoring

# ── Install Argo CD ───────────────────────────────────────────────────────────
echo "[BOOTSTRAP] Installing Argo CD..."
helm upgrade --install argo-cd argo/argo-cd \
  --namespace argocd \
  -f "$REPO_DIR/k8s-helm/argocd/values.yaml"

# --- Bootstrap Argo CD Application (Tripfinder) ---
APP_FILE="$REPO_DIR/k8s-helm/argocd/tripfinder-app.yaml"

echo "[BOOTSTRAP] Waiting for Argo CD CRD..."
until kubectl get crd applications.argoproj.io >/dev/null 2>&1; do
  sleep 5
done

kubectl -n argocd rollout status deployment/argocd-application-controller --timeout=300s || true

if [ -f "$APP_FILE" ]; then
  echo "[BOOTSTRAP] Applying Argo CD Application: $APP_FILE"
  kubectl -n argocd apply -f "$APP_FILE"
else
  echo "[BOOTSTRAP][WARN] $APP_FILE not found; skipping Argo Application bootstrap."
fi

echo "[BOOTSTRAP] Jenkins, Argo CD, Traefik, Monitoring, EBS CSI, StorageClass, and AWS Backup configured."

