#!/bin/bash
set -e
sleep 3
exec > >(tee /var/log/k8s-bootstrap.log | logger -t bootstrap -s) 2>&1

# Root check
if [[ $EUID -ne 0 ]]; then
  echo "Please run this script as root, e.g. sudo ./k8s-setup-master.sh"
  exit 1
fi

# Ensure hostname resolves locally
grep -q "$(hostname)" /etc/hosts || echo "127.0.1.1 $(hostname)" >> /etc/hosts

# ── Repo ──────────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/pmcann/Linux-Scripts.git"
REPO_DIR="/root/Linux-Scripts"
if [ -d "$REPO_DIR" ]; then
  echo "[BOOTSTRAP] Updating Linux-Scripts..."
  git -C "$REPO_DIR" pull
else
  echo "[BOOTSTRAP] Cloning Linux-Scripts..."
  git clone "$REPO_URL" "$REPO_DIR"
fi
cd "$REPO_DIR"

# ── Kernel / sysctl ───────────────────────────────────────────────────────────
swapoff -a
sed -i '/swap/d' /etc/fstab
cat >/etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay || true
modprobe br_netfilter || true
cat >/etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# ── Packages / containerd / kube ──────────────────────────────────────────────
apt update && apt-get update
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release unzip
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd

VERSION=1.32.7-1.1
apt-get install -y kubelet=$VERSION kubeadm=$VERSION kubectl=$VERSION
apt-mark hold kubelet kubeadm kubectl
kubeadm version && kubelet --version && kubectl version --client
systemctl enable --now kubelet
kubeadm config images pull

# ── Cluster init ──────────────────────────────────────────────────────────────
echo "[BOOTSTRAP] kubeadm init..."
kubeadm init --pod-network-cidr=10.244.0.0/16

REAL_USER=${SUDO_USER:-ubuntu}
USER_HOME=$(eval echo "~$REAL_USER")
mkdir -p "$USER_HOME/.kube"
cp /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
chown -R "$REAL_USER:$REAL_USER" "$USER_HOME/.kube"
export KUBECONFIG="$USER_HOME/.kube/config"

# DNS fix (VPC DNS + Google)
echo "Configuring resolv.conf with AWS VPC DNS and Google fallback..."
systemctl disable systemd-resolved || true
systemctl stop systemd-resolved || true
rm -f /etc/resolv.conf
cat >/etc/resolv.conf <<EOF
nameserver 172.31.0.2
nameserver 8.8.8.8
EOF

until kubectl version >/dev/null 2>&1; do
  echo "Waiting for API server..."
  sleep 5
done

# CNI
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
echo "Waiting for CoreDNS..."
until kubectl -n kube-system get pods | grep coredns | grep -q Running; do
  kubectl -n kube-system get pods
  sleep 5
done

# Smoke test
kubectl run testpod --image=nginx --restart=Never
while ! kubectl get pod testpod 2>/dev/null | grep -q Running; do
  echo "Waiting for testpod..."
  sleep 5
done
kubectl delete svc testpod-service --ignore-not-found
kubectl get svc nginx-nodeport >/dev/null 2>&1 || kubectl expose pod testpod --type=NodePort --port=80 --name=nginx-nodeport

# ── Helm ──────────────────────────────────────────────────────────────────────
echo "[BOOTSTRAP] Installing Helm..."
cd /tmp
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x get_helm.sh && ./get_helm.sh >> /var/log/k8s-bootstrap.log 2>&1 || true
rm -f get_helm.sh
helm version >> /var/log/k8s-bootstrap.log 2>&1 || echo "[WARN] Helm version check failed"

echo "[BOOTSTRAP] Adding Helm repos..."
helm repo add traefik https://traefik.github.io/charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add jenkinsci https://charts.jenkins.io
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update

# ── EBS CSI + StorageClass ────────────────────────────────────────────────────
echo "[BOOTSTRAP] Installing AWS EBS CSI driver..."
helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system \
  --set controller.serviceAccount.create=true \
  --set controller.serviceAccount.name=ebs-csi-controller-sa

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

# ── AWS CLI (arch auto-detect) ────────────────────────────────────────────────
cd /tmp
ARCH="$(uname -m)"
if [ "$ARCH" = "x86_64" ]; then
  AWSCLI_ZIP="awscli-exe-linux-x86_64.zip"
else
  AWSCLI_ZIP="awscli-exe-linux-aarch64.zip"
fi
curl -s "https://awscli.amazonaws.com/${AWSCLI_ZIP}" -o awscliv2.zip
unzip -q awscliv2.zip
./aws/install -i /usr/local/aws-cli -b /usr/local/bin || true
rm -rf aws awscliv2.zip

# ── Namespaces ────────────────────────────────────────────────────────────────
kubectl create ns jenkins --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns argocd  --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns monitoring --dry-run=client -o yaml | kubectl apply -f -
sleep 5

# ── SSM pulls / secrets / ECR ─────────────────────────────────────────────────
ACCOUNT_ID="374965728115"
AWS_REGION="${AWS_REGION:-us-east-1}"
REGION="$AWS_REGION"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "[BOOTSTRAP] Creating Jenkins secrets..."
JENKINS_ADMIN_PASSWORD="$(aws ssm get-parameter --with-decryption --name /tripfinder/jenkins/admin_password --query 'Parameter.Value' --output text 2>/dev/null || echo 'ChangeMe!')"
GITHUB_PAT="$(aws ssm get-parameter --with-decryption --name /tripfinder/github/pat --query 'Parameter.Value' --output text 2>/dev/null || echo 'replace-me')"
ECR_PASS="$(aws ecr get-login-password --region "$REGION" 2>/dev/null || echo '')"

kubectl -n jenkins create secret generic jenkins-admin-secret \
  --from-literal=jenkins-admin-user=admin \
  --from-literal=jenkins-admin-password="$JENKINS_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n jenkins create secret generic jenkins-github \
  --from-literal=pat="$GITHUB_PAT" \
  --dry-run=client -o yaml | kubectl apply -f -

if [ -n "$ECR_PASS" ]; then
  kubectl -n jenkins create secret docker-registry ecr-dockercfg \
    --docker-server="${ECR_REGISTRY}" --docker-username=AWS \
    --docker-password="${ECR_PASS}" --docker-email=unused@example.com \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n jenkins create secret generic jenkins-ecr \
    --from-literal=password="$ECR_PASS" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n default create secret docker-registry ecr-secret \
    --docker-server="$ECR_REGISTRY" --docker-username=AWS \
    --docker-password="$ECR_PASS" --docker-email=unused@example.com \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n default patch serviceaccount default --type merge -p '{"imagePullSecrets":[{"name":"ecr-secret"}]}' || true
else
  echo "[BOOTSTRAP][WARN] Could not fetch ECR password; skipping ECR secrets."
fi

# Jenkins webhook secret (optional)
SSM_PATH="/tripfinder/github/webhookSecret"
GH_SECRET_VALUE=$(aws ssm get-parameter --with-decryption --name "$SSM_PATH" --query 'Parameter.Value' --output text 2>/dev/null | tr -d '\n')
if [ -n "$GH_SECRET_VALUE" ] && [ "$GH_SECRET_VALUE" != "None" ]; then
  kubectl -n jenkins create secret generic github-webhook-secret \
    --from-literal=text="$GH_SECRET_VALUE" \
    --dry-run=client -o yaml \
  | kubectl label --local -f - jenkins.io/credentials-type=secretText --overwrite -o yaml \
  | kubectl annotate --local -f - jenkins.io/credentials-id=github-webhook-secret \
      jenkins.io/credentials-description="GitHub Webhook Secret" --overwrite -o yaml \
  | kubectl apply -f - >> /var/log/k8s-bootstrap.log 2>&1
fi

# Jenkins env secret
args=()
[ -n "$GITHUB_PAT" ]            && args+=( --from-literal=GITHUB_TOKEN="$GITHUB_PAT" )
[ -n "$JENKINS_ADMIN_PASSWORD" ]&& args+=( --from-literal=JENKINS_ADMIN_PASSWORD="$JENKINS_ADMIN_PASSWORD" )
[ -n "$ECR_PASS" ]              && args+=( --from-literal=ECR_PASSWORD="$ECR_PASS" )
if [ ${#args[@]} -gt 0 ]; then
  kubectl -n jenkins create secret generic jenkins-env "${args[@]}" --dry-run=client -o yaml | kubectl apply -f - >> /var/log/k8s-bootstrap.log 2>&1
fi


# ── AWS Backup (non-fatal, exit-code aware) ───────────────────────────────────
echo "[BOOTSTRAP] Configuring AWS Backup (non-fatal block)..."
set +e
VAULT="tripfinder-vault"
PLAN_NAME="tripfinder-daily-30d"
SCHEDULE_CRON="cron(30 7 * * ? *)"   # 07:30 UTC (03:30 ET summer)
RETENTION_DAYS=30

# Make sure service-linked role exists (ok if it already does)
aws iam create-service-linked-role --aws-service-name backup.amazonaws.com >/dev/null 2>&1

# Check/create vault
VAULT_READY=0
if aws backup describe-backup-vault --backup-vault-name "${VAULT}" >/dev/null 2>&1; then
  echo "[BOOTSTRAP] Backup vault exists: ${VAULT}"
  VAULT_READY=1
else
  aws backup create-backup-vault --backup-vault-name "${VAULT}"
  if [ $? -eq 0 ]; then
    echo "[BOOTSTRAP] Created backup vault: ${VAULT}"
    VAULT_READY=1
  else
    echo "[BOOTSTRAP][WARN] Failed to create backup vault '${VAULT}'. Skipping plan/selection."
  fi
fi

if [ "$VAULT_READY" -eq 1 ]; then
  # Ensure plan
  PLAN_ID=$(aws backup list-backup-plans --query "BackupPlansList[?BackupPlanName=='${PLAN_NAME}'] | [0].BackupPlanId" --output text 2>/dev/null)
  if [ -z "$PLAN_ID" ] || [ "$PLAN_ID" = "None" ]; then
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
    PLAN_ID=$(aws backup create-backup-plan --backup-plan file:///tmp/plan-30d.json --query BackupPlanId --output text 2>/dev/null)
    if [ -n "$PLAN_ID" ] && [ "$PLAN_ID" != "None" ]; then
      echo "[BOOTSTRAP] Created backup plan: ${PLAN_NAME} (${PLAN_ID})"
    else
      echo "[BOOTSTRAP][WARN] Failed to create backup plan '${PLAN_NAME}'. Skipping selection."
      PLAN_ID=""
    fi
  else
    echo "[BOOTSTRAP] Backup plan exists: ${PLAN_NAME} (${PLAN_ID})"
  fi

  # Ensure selection (tag-based) if we have a plan
  if [ -n "$PLAN_ID" ]; then
    SLR_ARN=$(aws iam get-role --role-name AWSServiceRoleForBackup --query Role.Arn --output text 2>/dev/null)
    if [ -n "$SLR_ARN" ] && [ "$SLR_ARN" != "None" ]; then
      SEL_COUNT=$(aws backup list-backup-selections --backup-plan-id "$PLAN_ID" \
        --query "length(BackupSelectionsList[?SelectionName=='tag-backup-tripfinder'])" \
        --output text 2>/dev/null)
      if [ "$SEL_COUNT" = "0" ] || [ "$SEL_COUNT" = "None" ]; then
        cat >/tmp/selection.json <<EOF
{ "SelectionName": "tag-backup-tripfinder",
  "IamRoleArn": "${SLR_ARN}",
  "ListOfTags": [ { "ConditionType": "STRINGEQUALS",
                    "ConditionKey": "backup", "ConditionValue": "tripfinder" } ] }
EOF
        if aws backup create-backup-selection --backup-plan-id "$PLAN_ID" --backup-selection file:///tmp/selection.json >/dev/null 2>&1; then
          echo "[BOOTSTRAP] Created backup selection 'tag-backup-tripfinder'"
        else
          echo "[BOOTSTRAP][WARN] Failed to create backup selection."
        fi
      else
        echo "[BOOTSTRAP] Backup selection already present."
      fi
    else
      echo "[BOOTSTRAP][WARN] Service-linked role not found; skipping selection."
    fi
  fi
fi
set -e




# Hourly PV auto-tagger
install -m 0755 /dev/stdin /usr/local/bin/tag-pv-volumes.sh <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
LOG="/var/log/tag-pv-volumes.log"
VOL_IDS=$(kubectl get pv -o jsonpath='{range .items[*]}{.spec.csi.volumeHandle}{"\n"}{end}' 2>/dev/null | grep '^vol-' || true)
[ -z "$VOL_IDS" ] && { echo "$(date -Is) no PV-backed volumes found" >> "$LOG"; exit 0; }
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

# ── Traefik ───────────────────────────────────────────────────────────────────
echo "[BOOTSTRAP] Installing Traefik..."
kubectl get ns traefik >/dev/null 2>&1 || kubectl create namespace traefik
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

# ── Jenkins RBAC (secrets read) ───────────────────────────────────────────────
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

# ── Jenkins on PVC (ebs-gp3) ─────────────────────────────────────────────────
echo "[BOOTSTRAP] Installing Jenkins (PVC on ebs-gp3)..."
HELM_ARGS=(
  upgrade --install jenkins jenkinsci/jenkins
  -n jenkins
  -f "$REPO_DIR/k8s-helm/jenkins/values.yaml"
  -f "$REPO_DIR/k8s-helm/jenkins/values-kubecloud.yaml"
  --set controller.serviceType=NodePort
  --set controller.servicePort=8080
  --set controller.nodePort=32010
  --set persistence.enabled=true
  --set persistence.storageClass=ebs-gp3
  --set persistence.size=30Gi
  --wait --timeout 10m
)
max=6
for i in $(seq 1 $max); do
  helm repo add jenkinsci https://charts.jenkins.io >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true
  if helm "${HELM_ARGS[@]}" >> /var/log/k8s-bootstrap.log 2>&1; then
    echo "[BOOTSTRAP] Jenkins installed/updated."
    break
  fi
  [ "$i" -lt "$max" ] && { sleep $((i*15)); echo "[WARN] Retry Jenkins ($i/$max)..."; } || { echo "[ERROR] Jenkins install failed."; exit 1; }
done

echo "[BOOTSTRAP] Waiting for Jenkins PVC..."
for _ in $(seq 1 60); do
  phase=$(kubectl -n jenkins get pvc jenkins -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$phase" = "Bound" ] && break
  sleep 5
done
if [ "$phase" != "Bound" ]; then
  echo "[ERROR] Jenkins PVC did not bind."; kubectl -n jenkins get pvc jenkins || true; exit 1
fi
PV_NAME=$(kubectl -n jenkins get pvc jenkins -o jsonpath='{.spec.volumeName}')
VOL_ID=$(kubectl get pv "$PV_NAME" -o jsonpath='{.spec.csi.volumeHandle}')
AZ=$(kubectl get pv "$PV_NAME" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[?(@.key=="topology.ebs.csi.aws.com/zone")].values[0]}')
echo "[BOOTSTRAP] Jenkins PV=$PV_NAME VOL=$VOL_ID AZ=$AZ"
aws ec2 create-tags --resources "$VOL_ID" --tags Key=backup,Value=tripfinder >/dev/null 2>&1 || echo "[WARN] Failed to tag $VOL_ID."
kubectl -n jenkins rollout status statefulset/jenkins --timeout=10m

# Jenkins agents RBAC
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

# ── Prometheus + Grafana on PVCs (ebs-gp3) ────────────────────────────────────
echo "[BOOTSTRAP] Installing Prometheus + Grafana (PVCs on ebs-gp3)..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1 || true

helm upgrade --install prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f "$REPO_DIR/k8s-monitoring/values.yaml" \
  --set prometheus.prometheusSpec.retention=14d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=ebs-gp3 \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=30Gi \
  --set grafana.persistence.enabled=true \
  --set grafana.persistence.type=pvc \
  --set grafana.persistence.storageClassName=ebs-gp3 \
  --set grafana.persistence.size=5Gi \
  --wait --timeout 15m >> /var/log/k8s-bootstrap.log 2>&1 || { echo "[ERROR] kube-prometheus-stack failed."; exit 1; }

kubectl apply -f "$REPO_DIR/k8s-monitoring/service-monitor-traefik.yaml" -n monitoring || true
kubectl apply -f "$REPO_DIR/k8s-monitoring/service-monitor-backend.yaml" -n monitoring || true

echo "[BOOTSTRAP] Waiting for Prometheus Ready..."
kubectl -n monitoring wait --for=condition=Ready pod -l app.kubernetes.io/name=prometheus --timeout=10m || true
echo "[BOOTSTRAP] Waiting for Grafana Ready..."
kubectl -n monitoring wait --for=condition=Ready pod -l app.kubernetes.io/name=grafana --timeout=10m || true

echo "[BOOTSTRAP] Tagging monitoring PV volumes..."
kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.claimRef.namespace}{"|"}{.spec.csi.volumeHandle}{"\n"}{end}' \
 | awk -F'|' '$2=="monitoring" && $3 ~ /^vol-/ {print $3}' \
 | while read -r VOL; do aws ec2 create-tags --resources "$VOL" --tags Key=backup,Value=tripfinder >/dev/null 2>&1 || echo "[WARN] Failed to tag $VOL"; done

# ── Argo CD ───────────────────────────────────────────────────────────────────
echo "[BOOTSTRAP] Installing Argo CD..."
helm upgrade --install argo-cd argo/argo-cd \
  --namespace argocd \
  -f "$REPO_DIR/k8s-helm/argocd/values.yaml"

APP_FILE="$REPO_DIR/k8s-helm/argocd/tripfinder-app.yaml"
echo "[BOOTSTRAP] Waiting for Argo CD CRD..."
until kubectl get crd applications.argoproj.io >/dev/null 2>&1; do sleep 5; done
kubectl -n argocd rollout status deployment/argocd-application-controller --timeout=300s || true
if [ -f "$APP_FILE" ]; then
  echo "[BOOTSTRAP] Applying Argo Application..."
  kubectl -n argocd apply -f "$APP_FILE"
else
  echo "[BOOTSTRAP][WARN] $APP_FILE not found; skipping Argo Application bootstrap."
fi

echo "[BOOTSTRAP] Done: Jenkins, Traefik, Monitoring, Argo CD, EBS CSI, StorageClass, AWS Backup (non-fatal)."

