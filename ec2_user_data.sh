#!/bin/bash
set -e

# Función para logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Función para manejar errores
handle_error() {
    log "ERROR: $1"
    exit 1
}

# Variables de entorno
export CLUSTER_NAME=${CLUSTER_NAME:-"cluster-PIN"}
export AWS_REGION=${AWS_REGION:-"us-east-1"}
export NODE_TYPE=${NODE_TYPE:-"t3.medium"}
export NODE_COUNT=${NODE_COUNT:-3}

# Actualizar el sistema e instalar dependencias
log "Actualizando el sistema e instalando dependencias..."
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common unzip

# Instalar Docker
log "Instalando Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker ubuntu

# Instalar kubectl
log "Instalando kubectl..."
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Instalar eksctl
log "Instalando eksctl..."
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

# Instalar Helm
log "Instalando Helm..."
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

# Crear cluster EKS
log "Creando cluster EKS..."
eksctl create cluster \
  --name $CLUSTER_NAME \
  --version 1.30 \
  --region $AWS_REGION \
  --nodegroup-name PIN-nodes \
  --node-type $NODE_TYPE \
  --nodes $NODE_COUNT \
  --nodes-min 1 \
  --nodes-max 4 \
  --managed \
  --asg-access \
  --external-dns-access \
  --full-ecr-access \
  --appmesh-access \
  --alb-ingress-access \
  

# Configurar kubectl
log "Configurando kubectl..."
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION

# Instalar el CSI driver para EBS
# log "Instalando el CSI driver para EBS..."
# kubectl apply -k "github.com/kubernetes-sigs/aws-ebs-csi-driver/deploy/kubernetes/overlays/stable/?ref=master"


helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm upgrade --install loki grafana/loki-stack --set grafana.enabled=true

kubectl get secret --namespace default loki-grafana -o jsonpath="{.data.admin-password}" | base64 --decode ; echo
kubectl port-forward --namespace default service/loki-grafana 3000:80

log "Configuración del cluster EKS completada."