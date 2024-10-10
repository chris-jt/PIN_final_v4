#!/bin/bash
set -x

# Variables de entorno
export CLUSTER_NAME=${CLUSTER_NAME:-"cluster-PIN"}
export AWS_REGION=${AWS_REGION:-"us-east-1"}
export NODE_TYPE=${NODE_TYPE:-"t3.medium"}
export NODE_COUNT=${NODE_COUNT:-3}

# Función para esperar a que apt esté disponible
wait_for_apt() {
  while sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 ; do
    echo "Esperando a que otras operaciones de apt terminen..."
    sleep 5
  done
}
# Función para logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Función para manejar errores
handle_error() {
    log "ERROR: $1"
    exit 1
}

# Función para verificar el estado de los pods
check_pod_status() {
    namespace=$1
    echo "Verificando el estado de los pods en el namespace $namespace..."
    kubectl get pods -n $namespace
    
    # Esperar hasta que todos los pods estén en estado Running o Completed
    while [[ $(kubectl get pods -n $namespace -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' | grep -v True) != "" ]]; do
        echo "Esperando que todos los pods estén listos..."
        sleep 10
        kubectl get pods -n $namespace
    done
    
    echo "Todos los pods están listos en el namespace $namespace."
}

# Actualizar el sistema
log "Actualizando el sistema..."
sudo apt-get update && sudo apt-get upgrade -y || handle_error "No se pudo actualizar el sistema"

echo "INSTALANDO Unzip"
wait_for_apt
sudo apt-get update
sudo apt-get install -y unzip
unzip -v

# Instalar dependencias
log "INSTALANDO dependencias..."
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common || handle_error "No se pudieron instalar las dependencias"

## Instalar Docker
log "INSTALANDO Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh || handle_error "No se pudo descargar el script de Docker"
sudo sh get-docker.sh || handle_error "No se pudo instalar Docker"
sudo usermod -aG docker ubuntu || handle_error "No se pudo añadir el usuario al grupo docker"

echo "INSTALANDO Docker Compose"
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
docker-compose --version

# Instalar kubectl
log "INSTALANDO kubectl..."
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" || handle_error "No se pudo descargar kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl || handle_error "No se pudo instalar kubectl"

# Instalar eksctl
log "INSTALANDO eksctl..."
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp || handle_error "No se pudo descargar eksctl"
sudo mv /tmp/eksctl /usr/local/bin || handle_error "No se pudo mover eksctl a /usr/local/bin"

# Instalar AWS CLI
log "INSTALANDO AWS CLI..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" || handle_error "No se pudo descargar AWS CLI"
unzip awscliv2.zip || handle_error "No se pudo descomprimir AWS CLI"
sudo ./aws/install || handle_error "No se pudo instalar AWS CLI"

# Instalar aws-iam-authenticator
curl -o aws-iam-authenticator https://amazon-eks.s3.us-west-2.amazonaws.com/1.21.2/2021-07-05/bin/linux/amd64/aws-iam-authenticator
chmod +x ./aws-iam-authenticator
sudo mv ./aws-iam-authenticator /usr/local/bin

# Crear cluster EKS
log "Creando cluster EKS..."
# eksctl create cluster --name $CLUSTER_NAME --region $AWS_REGION --node-type $NODE_TYPE --nodes $NODE_COUNT || handle_error "No se pudo crear el cluster EKS"
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
  --alb-ingress-access || handle_error "No se pudo crear el cluster EKS"

echo "Configurando kubectl para el cluster..."
if ! aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION; then
    echo "Error al actualizar kubeconfig"
    exit 1
fi

echo "Contenido de kubeconfig:"
cat ~/.kube/config

echo "Versión de kubectl:"
kubectl version --client

# Verificar que los nodos estén listos
log "Verificando que los nodos estén listos..."
kubectl get nodes --watch &
PID=$!
sleep 60
kill $PID

echo "Versión de AWS CLI:"
aws --version

echo "Probando conexión al cluster:"
if ! kubectl get nodes; then
    echo "Error al conectar con el cluster"
    exit 1
fi

# Verificar recursos disponibles
echo "Verificando recursos disponibles en el cluster..."
kubectl describe nodes | grep -A 5 "Allocated resources"

# Verificar clases de almacenamiento
echo "Verificando clases de almacenamiento disponibles..."
kubectl get storageclass

# Crear namespace para monitoreo
echo "Creando namespace para monitoreo..."
kubectl create namespace monitoring

log "Configuración completada. El cluster EKS está listo para usar."

echo "Instalando Helm"
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
helm version

# Add Prometheus Helm repository
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install prometheus prometheus-community/prometheus \
    --namespace monitoring \
    --set alertmanager.persistentVolume.enabled=false \
    --set server.persistentVolume.enabled=false \
    --set alertmanager.emptyDir.enabled=true \
    --set server.emptyDir.enabled=true \
    --set server.resources.limits.cpu=500m \
    --set server.resources.limits.memory=512Mi

# Esperar y verificar el estado de Prometheus
sleep 30
check_pod_status monitoring

# Add Grafana Helm repository
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Installando Grafana
helm install grafana grafana/grafana \
    --namespace monitoring \
    --set persistence.enabled=false \
    --set adminPassword='adminPIN' \
    --set service.type=LoadBalancer \
    --set volumes[0].name=storage \
    --set volumes[0].emptyDir={} \
    --set volumeMounts[0].name=storage \
    --set volumeMounts[0].mountPath=/var/lib/grafana

# Esperar y verificar el estado de Grafana
sleep 30
check_pod_status monitoring

# Obtener URL y contraseña de Grafana
echo "Obteniendo URL y contraseña de Grafana..."
GRAFANA_PASSWORD=""
GRAFANA_URL=""

# Esperar hasta que el secreto de Grafana esté disponible
while [ -z "$GRAFANA_PASSWORD" ]; do
    echo "Esperando que el secreto de Grafana esté disponible..."
    GRAFANA_PASSWORD=$(kubectl get secret --namespace monitoring grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 --decode)
    [ -z "$GRAFANA_PASSWORD" ] && sleep 10
done

# Esperar hasta que el LoadBalancer de Grafana esté listo
while [ -z "$GRAFANA_URL" ]; do
    echo "Esperando que el LoadBalancer de Grafana esté listo..."
    GRAFANA_URL=$(kubectl get svc -n monitoring grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    [ -z "$GRAFANA_URL" ] && sleep 10
done

# Guardar la URL y la contraseña de Grafana en el archivo de conexiones
echo "URL de Grafana: http://$GRAFANA_URL" >> connection_info.txt
echo "Contraseña de Grafana: $GRAFANA_PASSWORD" >> connection_info.txt

# Configurar port-forward para Prometheus (en segundo plano)
kubectl port-forward -n monitoring svc/prometheus-server 9090:80 &

echo "Prometheus está disponible en http://localhost:9090"

echo "verificando prometheus y grafana"
kubectl get all -n monitoring

# Asegurarse de que las configuraciones estén disponibles para el usuario ubuntu
mkdir -p /home/ubuntu/.kube
mkdir -p /root/.kube
sudo sudo cp /root/.kube/config /home/ubuntu/.kube/config
sudo chown ubuntu:ubuntu /home/ubuntu/.kube/config

# Añadir kubectl al PATH del usuario ubuntu
echo 'export PATH=$PATH:/usr/local/bin' >> /home/ubuntu/.bashrc
source /home/ubuntu/.bashrc

aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION

echo "All necessary tools have been installed and cluster is ready."