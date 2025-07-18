#!/bin/bash

# Script to generate certificates and bootstrap token for external worker nodes
# Run this on your control plane (Clever Cloud instance)

set -e

# Function to generate node certificates
generate_node_certs() {
    local NODE_NAME=$1
    local NODE_IP=$2
    
    echo "Generating certificates for node: $NODE_NAME ($NODE_IP)"
    
    cd certs
    
    # Create node certificate signing request
    cat > ${NODE_NAME}-csr.json <<EOF
{
  "CN": "system:node:${NODE_NAME}",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "FR",
      "L": "Pessac",
      "O": "system:nodes",
      "OU": "dumber k8s",
      "ST": "Nouvelle Aquitaine"
    }
  ],
  "hosts": [
    "${NODE_IP}",
    "${NODE_NAME}",
    "localhost",
    "127.0.0.1"
  ]
}
EOF

    # Generate node certificate
    cfssl gencert \
      -ca=ca.pem \
      -ca-key=ca-key.pem \
      -config=ca-config.json \
      -profile=kubernetes \
      ${NODE_NAME}-csr.json | ../bin/cfssljson -bare ${NODE_NAME}
    
    cd ..
    
    echo "Certificates generated for $NODE_NAME"
}

# Function to create bootstrap token
create_bootstrap_token() {
    echo "Creating bootstrap token..."
    
    # Generate a random token
    TOKEN_ID=$(head -c 6 /dev/urandom | xxd -p)
    TOKEN_SECRET=$(head -c 16 /dev/urandom | xxd -p)
    TOKEN="${TOKEN_ID}.${TOKEN_SECRET}"
    
    # Create token secret
    cat > bootstrap-token.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-token-${TOKEN_ID}
  namespace: kube-system
type: bootstrap.kubernetes.io/token
data:
  token-id: $(echo -n ${TOKEN_ID} | base64 -w 0)
  token-secret: $(echo -n ${TOKEN_SECRET} | base64 -w 0)
  usage-bootstrap-authentication: $(echo -n "true" | base64 -w 0)
  usage-bootstrap-signing: $(echo -n "true" | base64 -w 0)
  auth-extra-groups: $(echo -n "system:bootstrappers:worker" | base64 -w 0)
EOF

    # Apply the token
    bin/kubectl apply -f bootstrap-token.yaml
    
    echo "Bootstrap token created: $TOKEN"
    echo "Save this token for node setup!"
    
    # Save token to file for reference
    echo "$TOKEN" > bootstrap-token.txt
    
    return 0
}

# Function to create RBAC for node bootstrap
create_node_rbac() {
    echo "Creating RBAC for node bootstrap..."
    
    cat > node-bootstrap-rbac.yaml <<EOF
# Allow bootstrap tokens to create CSRs
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: create-csrs-for-bootstrapping
subjects:
- kind: Group
  name: system:bootstrappers:worker
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: system:node-bootstrapper
  apiGroup: rbac.authorization.k8s.io
---
# Auto-approve CSRs for the group
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: auto-approve-csrs-for-group
subjects:
- kind: Group
  name: system:bootstrappers:worker
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: system:certificates.k8s.io:certificatesigningrequests:nodeclient
  apiGroup: rbac.authorization.k8s.io
---
# Auto-approve renewal CSRs for nodes
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: auto-approve-renewals-for-nodes
subjects:
- kind: Group
  name: system:nodes
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: system:certificates.k8s.io:certificatesigningrequests:selfnodeclient
  apiGroup: rbac.authorization.k8s.io
EOF

    bin/kubectl apply -f node-bootstrap-rbac.yaml
    echo "RBAC rules created"
}

# Function to generate worker node setup script
generate_worker_setup_script() {
    local API_SERVER_ENDPOINT="https://dumberk8s.zwindler.fr:5332"
    local BOOTSTRAP_TOKEN=$(cat bootstrap-token.txt 2>/dev/null || echo "REPLACE_WITH_BOOTSTRAP_TOKEN")
    
    cat > setup-worker-node.sh <<'EOF'
#!/bin/bash

# External Worker Node Setup Script for Kubernetes
# Run this script on your external worker node

set -e

# Configuration - EDIT THESE VALUES
NODE_NAME="worker-1"  # Change this to your node name
NODE_IP="YOUR_NODE_IP"  # Change this to your external node IP
API_SERVER_ENDPOINT="https://dumberk8s.zwindler.fr:5332"
BOOTSTRAP_TOKEN="REPLACE_WITH_BOOTSTRAP_TOKEN"  # Replace with actual token
K8S_VERSION="1.33.2"

# Create directories
sudo mkdir -p /etc/kubernetes/{manifests,pki}
sudo mkdir -p /var/lib/{kubelet,kube-proxy}
sudo mkdir -p /opt/cni/bin
sudo mkdir -p /etc/cni/net.d

# Download and install container runtime (containerd)
echo "Installing containerd..."
CONTAINERD_VERSION="1.7.22"
curl -L https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz -o containerd.tar.gz
sudo tar -C /usr/local -xzf containerd.tar.gz
sudo mkdir -p /usr/local/lib/systemd/system
curl -L https://raw.githubusercontent.com/containerd/containerd/main/containerd.service -o containerd.service
sudo mv containerd.service /usr/local/lib/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now containerd

# Configure containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd

# Download and install runc
echo "Installing runc..."
RUNC_VERSION="1.1.14"
curl -L https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64 -o runc
sudo install -m 755 runc /usr/local/sbin/runc

# Download and install CNI plugins
echo "Installing CNI plugins..."
CNI_VERSION="1.5.1"
curl -L https://github.com/containernetworking/plugins/releases/download/v${CNI_VERSION}/cni-plugins-linux-amd64-v${CNI_VERSION}.tgz -o cni-plugins.tgz
sudo tar -C /opt/cni/bin -xzf cni-plugins.tgz

# Download Kubernetes binaries
echo "Downloading Kubernetes binaries..."
curl -L https://dl.k8s.io/v${K8S_VERSION}/kubernetes-node-linux-amd64.tar.gz -o kubernetes-node.tar.gz
tar -xzf kubernetes-node.tar.gz
sudo cp kubernetes/node/bin/{kubelet,kube-proxy} /usr/local/bin/
sudo chmod +x /usr/local/bin/{kubelet,kube-proxy}

# Create CA certificate (you need to copy this from your control plane)
sudo tee /etc/kubernetes/pki/ca.crt <<'CA_CERT_EOF'
# REPLACE THIS WITH YOUR ACTUAL CA CERTIFICATE FROM certs/ca.pem
CA_CERT_EOF

# Create kubelet bootstrap kubeconfig
sudo tee /etc/kubernetes/bootstrap-kubelet.conf <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority: /etc/kubernetes/pki/ca.crt
    server: ${API_SERVER_ENDPOINT}
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: kubelet-bootstrap
  name: default
current-context: default
users:
- name: kubelet-bootstrap
  user:
    token: ${BOOTSTRAP_TOKEN}
EOF

# Create kubelet configuration
sudo tee /var/lib/kubelet/config.yaml <<EOF
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: "/etc/kubernetes/pki/ca.crt"
authorization:
  mode: Webhook
clusterDomain: "cluster.local"
clusterDNS:
  - "10.32.0.10"
runtimeRequestTimeout: "15m"
tlsCertFile: "/var/lib/kubelet/pki/kubelet.crt"
tlsPrivateKeyFile: "/var/lib/kubelet/pki/kubelet.key"
containerRuntimeEndpoint: "unix:///var/run/containerd/containerd.sock"
EOF

# Create kubelet systemd service
sudo tee /etc/systemd/system/kubelet.service <<EOF
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \\
  --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \\
  --kubeconfig=/etc/kubernetes/kubelet.conf \\
  --config=/var/lib/kubelet/config.yaml \\
  --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock \\
  --node-ip=${NODE_IP} \\
  --hostname-override=${NODE_NAME} \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Create kube-proxy kubeconfig (you need to create this on control plane first)
sudo tee /etc/kubernetes/kube-proxy.conf <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority: /etc/kubernetes/pki/ca.crt
    server: ${API_SERVER_ENDPOINT}
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: kube-proxy
  name: default
current-context: default
users:
- name: kube-proxy
  user:
    token: ${BOOTSTRAP_TOKEN}
EOF

# Create kube-proxy configuration
sudo tee /var/lib/kube-proxy/config.conf <<EOF
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: "/etc/kubernetes/kube-proxy.conf"
mode: "iptables"
clusterCIDR: "10.0.0.0/16"
EOF

# Create kube-proxy systemd service
sudo tee /etc/systemd/system/kube-proxy.service <<EOF
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-proxy \\
  --config=/var/lib/kube-proxy/config.conf \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Enable and start services
sudo systemctl daemon-reload
sudo systemctl enable kubelet kube-proxy
sudo systemctl start kubelet kube-proxy

echo "Worker node setup completed!"
echo "Check status with: sudo systemctl status kubelet kube-proxy"
echo "Check logs with: sudo journalctl -u kubelet -f"
EOF

    chmod +x setup-worker-node.sh
    
    # Replace the bootstrap token in the script
    sed -i "s/REPLACE_WITH_BOOTSTRAP_TOKEN/${BOOTSTRAP_TOKEN}/" setup-worker-node.sh
    
    echo "Worker setup script generated: setup-worker-node.sh"
}

# Main execution
main() {
    echo "=== Kubernetes External Node Setup Generator ==="
    echo ""
    
    # Check if we're in the right directory
    if [[ ! -f "bin/kubectl" ]]; then
        echo "Error: kubectl not found. Make sure you're in the kubernetes directory."
        exit 1
    fi
    
    # Create RBAC
    create_node_rbac
    
    # Create bootstrap token
    create_bootstrap_token
    
    # Generate worker setup script
    generate_worker_setup_script
    
    echo ""
    echo "=== Setup Complete ==="
    echo "1. Copy setup-worker-node.sh to your external worker node"
    echo "2. Copy certs/ca.pem content and replace CA_CERT_EOF section in the script"
    echo "3. Edit NODE_NAME and NODE_IP in setup-worker-node.sh"
    echo "4. Run the script on your worker node with sudo privileges"
    echo ""
    echo "Bootstrap token saved in: bootstrap-token.txt"
}

# Handle arguments
if [[ $# -eq 2 ]]; then
    generate_node_certs "$1" "$2"
else
    main
fi
