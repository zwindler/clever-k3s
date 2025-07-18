#!/bin/bash

# Generate setup script for external worker nodes
set -e

echo "=== Generating worker node setup script ==="

# Configuration
API_SERVER_ENDPOINT="https://dumberk8s.zwindler.fr:5332"
BOOTSTRAP_TOKEN=$(cat bootstrap-token.txt 2>/dev/null || echo "REPLACE_WITH_BOOTSTRAP_TOKEN")

# Check if CA certificate exists
if [[ ! -f "certs/ca.pem" ]]; then
    echo "Error: CA certificate not found. Make sure certificates are generated first."
    exit 1
fi

echo "Creating worker node setup script..."

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

echo "=== Setting up Kubernetes worker node: $NODE_NAME ==="

# Create directories
echo "Creating directories..."
sudo mkdir -p /etc/kubernetes/{manifests,pki}
sudo mkdir -p /var/lib/{kubelet,kube-proxy}
sudo mkdir -p /opt/cni/bin
sudo mkdir -p /etc/cni/net.d

# Install container runtime (containerd)
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
echo "Configuring containerd..."
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd

# Install runc
echo "Installing runc..."
RUNC_VERSION="1.1.14"
curl -L https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64 -o runc
sudo install -m 755 runc /usr/local/sbin/runc

# Install CNI plugins
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

# Create CA certificate (replace with actual content)
echo "Creating CA certificate..."
sudo tee /etc/kubernetes/pki/ca.crt <<'CA_CERT_EOF'
REPLACE_WITH_CA_CERTIFICATE
CA_CERT_EOF

# Create kubelet bootstrap kubeconfig
echo "Creating kubelet bootstrap configuration..."
sudo tee /etc/kubernetes/bootstrap-kubelet.conf <<BOOTSTRAP_EOF
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
BOOTSTRAP_EOF

# Create kubelet configuration
echo "Creating kubelet configuration..."
sudo tee /var/lib/kubelet/config.yaml <<KUBELET_CONFIG_EOF
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
KUBELET_CONFIG_EOF

# Create kubelet systemd service
echo "Creating kubelet service..."
sudo tee /etc/systemd/system/kubelet.service <<KUBELET_SERVICE_EOF
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
KUBELET_SERVICE_EOF

# Create kube-proxy kubeconfig
echo "Creating kube-proxy configuration..."
sudo tee /etc/kubernetes/kube-proxy.conf <<PROXY_CONFIG_EOF
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
PROXY_CONFIG_EOF

# Create kube-proxy configuration
echo "Creating kube-proxy configuration..."
sudo tee /var/lib/kube-proxy/config.conf <<PROXY_YAML_EOF
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: "/etc/kubernetes/kube-proxy.conf"
mode: "iptables"
clusterCIDR: "10.0.0.0/16"
PROXY_YAML_EOF

# Create kube-proxy systemd service
echo "Creating kube-proxy service..."
sudo tee /etc/systemd/system/kube-proxy.service <<PROXY_SERVICE_EOF
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
PROXY_SERVICE_EOF

# Enable and start services
echo "Starting services..."
sudo systemctl daemon-reload
sudo systemctl enable kubelet kube-proxy
sudo systemctl start kubelet kube-proxy

echo ""
echo "✓ Worker node setup completed!"
echo ""
echo "Check status with:"
echo "  sudo systemctl status kubelet"
echo "  sudo systemctl status kube-proxy"
echo ""
echo "Check logs with:"
echo "  sudo journalctl -u kubelet -f"
echo "  sudo journalctl -u kube-proxy -f"
EOF

chmod +x setup-worker-node.sh

# Replace the bootstrap token in the script
if [[ "$BOOTSTRAP_TOKEN" != "REPLACE_WITH_BOOTSTRAP_TOKEN" ]]; then
    sed -i "s/REPLACE_WITH_BOOTSTRAP_TOKEN/${BOOTSTRAP_TOKEN}/" setup-worker-node.sh
fi

# Replace CA certificate in the script
if [[ -f "certs/ca.pem" ]]; then
    CA_CONTENT=$(cat certs/ca.pem)
    # Use a more complex sed command to handle multiline replacement
    sed -i "/REPLACE_WITH_CA_CERTIFICATE/c\\${CA_CONTENT}" setup-worker-node.sh
fi

echo "✓ Worker setup script generated: setup-worker-node.sh"
echo ""
echo "📋 Next steps:"
echo "1. Copy setup-worker-node.sh to your external worker node"
echo "2. Edit NODE_NAME and NODE_IP variables in the script"
echo "3. Run the script on your worker node with sudo privileges"
echo "4. Check the node joined with: kubectl get nodes"
