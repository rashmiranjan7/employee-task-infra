#!/bin/bash
# Runs once, automatically, when the EC2 instance boots (passed in as
# user_data in main.tf). Installs everything the Jenkinsfile needs:
# Docker, Jenkins itself, kubectl, Helm, Trivy, and Node.js.
#
# Log file if something goes wrong: /var/log/cloud-init-output.log

set -euo pipefail

apt-get update -y
apt-get install -y openjdk-17-jdk git curl unzip jq awscli

# ─── Docker ─────────────────────────────────────────────────────────────────
apt-get install -y docker.io
systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu

# ─── Jenkins ────────────────────────────────────────────────────────────────
# Jenkins rotated their apt signing key in Dec 2025 - the URL changed from
# jenkins.io-2023.key to jenkins.io-2026.key. See:
# https://www.jenkins.io/blog/2025/12/23/repository-signing-keys-changing/
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key \
  | tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null

echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  > /etc/apt/sources.list.d/jenkins.list

apt-get update -y
apt-get install -y jenkins
usermod -aG docker jenkins
systemctl enable jenkins
systemctl start jenkins

# ─── kubectl ────────────────────────────────────────────────────────────────
# Matches the EKS cluster's version (1.34) - kubectl only officially
# supports being at most 1 minor version off from the cluster it talks to.
curl -fsSL -o /usr/local/bin/kubectl \
  "https://dl.k8s.io/release/v1.34.0/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

# ─── Helm ───────────────────────────────────────────────────────────────────
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ─── Trivy (image scanning) ─────────────────────────────────────────────────
curl -fsSL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
  | sh -s -- -b /usr/local/bin v0.54.1

# ─── Node.js (backend/frontend build + test steps run this) ────────────────
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# Print the initial admin password to the instance log so it's easy to find
# with: aws ec2 get-console-output --instance-id <id>
echo "Waiting for Jenkins to start..."
for i in $(seq 1 30); do
  if [ -f /var/lib/jenkins/secrets/initialAdminPassword ]; then
    echo "Jenkins initial admin password:"
    cat /var/lib/jenkins/secrets/initialAdminPassword
    break
  fi
  sleep 5
done