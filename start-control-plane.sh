#!/bin/bash

# Start Kubernetes control plane components
set -e

echo "=== Starting Kubernetes control plane ==="

# Certificate options for API server
API_CERTS_OPTS="--client-ca-file=certs/ca.pem \
            --tls-cert-file=certs/admin.pem \
            --tls-private-key-file=certs/admin-key.pem \
            --service-account-key-file=certs/admin.pem \
            --service-account-signing-key-file=certs/admin-key.pem \
            --service-account-issuer=https://kubernetes.default.svc.cluster.local"

# etcd connection options
ETCD_OPTS="--etcd-cafile=certs/ca.pem \
           --etcd-certfile=certs/admin.pem \
           --etcd-keyfile=certs/admin-key.pem \
           --etcd-servers=https://127.0.0.1:2379"

# Start kube-apiserver
echo "Starting kube-apiserver..."
bin/kube-apiserver ${API_CERTS_OPTS} ${ETCD_OPTS} \
            --allow-privileged \
            --authorization-mode=Node,RBAC \
            --secure-port 4040 &

API_SERVER_PID=$!
echo "kube-apiserver started with PID: $API_SERVER_PID"

# Wait for API server to be ready
echo "Waiting for API server to be ready..."
sleep 5

# Certificate options for controller manager
CONTROLLER_CERTS_OPTS="--cluster-signing-cert-file=certs/ca.pem \
            --cluster-signing-key-file=certs/ca-key.pem \
            --service-account-private-key-file=certs/admin-key.pem \
            --root-ca-file=certs/ca.pem"

# Start kube-controller-manager
echo "Starting kube-controller-manager..."
bin/kube-controller-manager ${CONTROLLER_CERTS_OPTS} \
--kubeconfig admin.conf \
--use-service-account-credentials \
--cluster-cidr=10.0.0.0/16 \
--allocate-node-cidrs=true &

CONTROLLER_PID=$!
echo "kube-controller-manager started with PID: $CONTROLLER_PID"

# Start kube-scheduler
echo "Starting kube-scheduler..."
bin/kube-scheduler --kubeconfig admin.conf &

SCHEDULER_PID=$!
echo "kube-scheduler started with PID: $SCHEDULER_PID"

echo "✓ Control plane components started"
echo "API server: PID $API_SERVER_PID"
echo "Controller manager: PID $CONTROLLER_PID" 
echo "Scheduler: PID $SCHEDULER_PID"
