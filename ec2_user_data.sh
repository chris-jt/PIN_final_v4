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

# Función para esperar a que un comando sea exitoso
wait_for_command() {
    local cmd="$1"
    local timeout="${2:-300}"
    local interval="${3:-10}"
    
    local end_time=$((SECONDS + timeout))
    
    while [ $SECONDS -lt $end_time ]; do
        if eval "$cmd"; then
            return 0
        fi
        sleep "$interval"
    done
    
    handle_error "Timeout esperando que el comando sea exitoso: $cmd"
}

# Variables de entorno
export CLUSTER_NAME=${CLUSTER_NAME:-"cluster-PIN"}
export AWS_REGION=${AWS_REGION:-"us-east-1"}
export NODE_TYPE=${NODE_TYPE:-"t3.medium"}
export NODE_COUNT=${NODE_COUNT:-3}

# Actualizar el sistema
log "Actualizando el sistema..."
sudo apt-get update && sudo apt-get upgrade -y || handle_error "No se pudo actualizar el sistema"

# Instalar dependencias
log "Instalando dependencias..."
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common unzip || handle_error "No se pudieron instalar las dependencias"

# Instalar Docker
log "Instalando Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh || handle_error "No se pudo descargar el script de Docker"
sudo sh get-docker.sh || handle_error "No se pudo instalar Docker"
sudo usermod -aG docker ubuntu || handle_error "No se pudo añadir el usuario al grupo docker"

# Instalar Docker Compose
log "Instalando Docker Compose..."
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
docker-compose --version || handle_error "No se pudo instalar Docker Compose"

# Instalar kubectl
log "Instalando kubectl..."
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" || handle_error "No se pudo descargar kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl || handle_error "No se pudo instalar kubectl"

# Instalar eksctl
log "Instalando eksctl..."
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp || handle_error "No se pudo descargar eksctl"
sudo mv /tmp/eksctl /usr/local/bin || handle_error "No se pudo mover eksctl a /usr/local/bin"

# Instalar AWS CLI
log "Instalando AWS CLI..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" || handle_error "No se pudo descargar AWS CLI"
unzip awscliv2.zip || handle_error "No se pudo descomprimir AWS CLI"
sudo ./aws/install || handle_error "No se pudo instalar AWS CLI"

# Instalar aws-iam-authenticator
log "Instalando aws-iam-authenticator..."
curl -o aws-iam-authenticator https://amazon-eks.s3.us-west-2.amazonaws.com/1.21.2/2021-07-05/bin/linux/amd64/aws-iam-authenticator
chmod +x ./aws-iam-authenticator
sudo mv ./aws-iam-authenticator /usr/local/bin

log "Creando cluster EKS..."
eksctl create cluster \
  --name $CLUSTER_NAME  \
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
  --node-private-networking \
  --node-iam-instance-profile NodeInstanceRole \
  || handle_error "No se pudo crear el cluster EKS"

# Configurar kubectl
log "Configurando kubectl..."
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION || handle_error "No se pudo configurar kubectl"

# Verificar que los nodos estén listos
log "Verificando que los nodos estén listos..."
wait_for_command "kubectl get nodes | grep -q Ready" 600 30

# Instalar el CSI driver para EBS
log "Instalando el CSI driver para EBS..."
kubectl apply -k "github.com/kubernetes-sigs/aws-ebs-csi-driver/deploy/kubernetes/overlays/stable/?ref=master" || handle_error "No se pudo instalar el CSI driver para EBS"

# Crear namespace para monitoreo
log "Creando namespace para monitoreo..."
kubectl create namespace monitoring || handle_error "No se pudo crear el namespace de monitoreo"

# Instalar Helm
log "Instalando Helm..."
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash || handle_error "No se pudo instalar Helm"

# Añadir repositorios de Helm
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Instalar Prometheus
log "Instalando Prometheus..."
helm install prometheus prometheus-community/prometheus \
    --namespace monitoring \
    --set alertmanager.persistentVolume.storageClass="gp2" \
    --set server.persistentVolume.storageClass="gp2" \
    --set server.persistentVolume.size=20Gi \
    --set server.retention=15d || handle_error "No se pudo instalar Prometheus"

# Esperar que Prometheus esté listo
log "Esperando que Prometheus esté listo..."
wait_for_command "kubectl get pods -n monitoring -l app=prometheus -o jsonpath='{.items[*].status.containerStatuses[0].ready}' | grep -q true" 600 30

# Instalar Grafana
log "Instalando Grafana..."
helm install grafana grafana/grafana \
    --namespace monitoring \
    --set persistence.storageClassName="gp2" \
    --set persistence.enabled=true \
    --set adminPassword='adminPIN' \
    --set persistence.size=10Gi \
    --set service.type=LoadBalancer || handle_error "No se pudo instalar Grafana"

# Esperar que Grafana esté listo
log "Esperando que Grafana esté listo..."
wait_for_command "kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[*].status.containerStatuses[0].ready}' | grep -q true" 600 30

# Obtener URL y contraseña de Grafana
log "Obteniendo URL y contraseña de Grafana..."
GRAFANA_PASSWORD=$(kubectl get secret --namespace monitoring grafana -o jsonpath="{.data.admin-password}" | base64 --decode)
GRAFANA_URL=$(kubectl get svc -n monitoring grafana -o jsonpath="{.status.loadBalancer.ingress[0].hostname}")

# Esperar a que la URL de Grafana esté disponible
MAX_RETRIES=20
RETRY_INTERVAL=30
for i in $(seq 1 $MAX_RETRIES); do
  if [ ! -z "$GRAFANA_URL" ]; then
    break
  fi
  log "Intento $i: Esperando que la URL de Grafana esté disponible..."
  sleep $RETRY_INTERVAL
  GRAFANA_URL=$(kubectl get svc -n monitoring grafana -o jsonpath="{.status.loadBalancer.ingress[0].hostname}")
done

if [ -z "$GRAFANA_URL" ]; then
  handle_error "No se pudo obtener la URL de Grafana después de $MAX_RETRIES intentos"
fi

# Guardar la información de conexión
echo "URL de Grafana: http://$GRAFANA_URL" >> ~/connection_info.txt
echo "Contraseña de Grafana: $GRAFANA_PASSWORD" >> ~/connection_info.txt

# Configurar port-forward para Prometheus (en segundo plano)
kubectl port-forward -n monitoring svc/prometheus-server 9090:80 &

log "Prometheus está disponible en http://localhost:9090"

# Verificar el estado de todos los pods
log "Verificando el estado de todos los pods..."
kubectl get pods --all-namespaces

# Mostrar información del cluster
log "Información del cluster:"
kubectl cluster-info

log "Configuración completada. El cluster EKS está listo para usar."