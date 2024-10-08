# Proyecto de Despliegue en AWS EKS

Este proyecto implementa un pipeline de CI/CD para desplegar una instancia EC2 en AWS, crear un cluster EKS, y desplegar una aplicación Nginx junto con herramientas de monitoreo (EFK stack y Prometheus/Grafana).

## Estructura del Proyecto

├── .github
│   └── workflows
│       └── main.yaml
├── cloudformation
│   └── ec2-stack.yaml
├── kubernetes
│   ├── elasticsearch.yaml
│   ├── fluentd-configmap.yaml
│   ├── fluentd-daemonset.yaml
│   ├── fluentd-rbac.yaml
│   ├── fkibana.yaml
│   ├── nginx-index-html-configmap.yaml
│   ├── nginx-deployment.yaml
│   ├── nginx-service.yaml
│   └── prometheus-grafana.yaml
├── scripts
│    └── deploy-efk.sh
├── ec2_user_data.sh
└── README.md

## Funcionamiento

1. El workflow de GitHub Actions se activa manualmente.
2. Se crea una instancia EC2 utilizando CloudFormation.
3. Se configura la instancia EC2 con las herramientas necesarias (Docker, kubectl, eksctl, etc.).
4. Se crea un cluster EKS en AWS.
5. Se despliega un pod de Nginx con una página personalizada.
6. Se despliega el stack EFK (Elasticsearch, Fluentd, Kibana) para monitoreo de logs.
7. Se despliega Prometheus y Grafana para métricas y visualización.

## Acceso a la Instancia EC2

Para acceder a la instancia EC2 desde una PC remota:

1. Descarga la clave SSH `jenkins.pem` del artefacto generado por el workflow.
2. Abre una terminal y navega hasta el directorio donde guardaste la clave.
3. Cambia los permisos de la clave:

        chmod 400 jenkins.pem

4. Conéctate a la instancia EC2 usando el comando:

        ssh -i jenkins.pem ubuntu@`<EC2_PUBLIC_IP>

    Reemplaza `<EC2_PUBLIC_IP>` con la IP pública de la instancia EC2 que encontrarás en el archivo `connection_info.txt`.

## Conexión al Cluster EKS

Para conectarte al cluster EKS desde la instancia EC2:

1. Una vez conectado a la instancia EC2, el archivo kubeconfig ya debería estar configurado.
2. Puedes verificar la conexión con:

        kubectl get nodes


## Integración con Lens

Para integrar el cluster con Lens desde tu PC remota:

1. Instala Lens en tu PC si aún no lo tienes.
2. Usa el archivo kubeconfig descargado del artefacto de GitHub Actions.
3. En Lens, añade un nuevo cluster usando este archivo kubeconfig.

## Acceso a Kibana y Grafana

Las URLs para acceder a Kibana y Grafana se encuentran en el archivo `connection_info.txt`. Estas interfaces son accesibles desde fuera del cloud para monitorear los logs y métricas de la aplicación.

## Conexión al Pod de Nginx desde una PC Remota

Para conectarte directamente al pod de Nginx desde tu PC remota:

1. Descarga el archivo kubeconfig del artefacto generado por el workflow de GitHub Actions.
2. Guarda el archivo kubeconfig en tu PC local, por ejemplo, en `~/eks-kubeconfig`.
3. Instala kubectl en tu PC local si aún no lo tienes instalado.
4. Configura la variable de entorno KUBECONFIG para usar el archivo descargado:

        export KUBECONFIG=~/eks-kubeconfig

5. Verifica que puedes conectarte al cluster:

        kubectl get nodes

6. Obtén el nombre del pod de Nginx:

        kubectl get pods -l app=nginx

7. Para conectarte directamente al pod de Nginx, usa el siguiente comando:

        kubectl exec -it `<nombre-del-pod-nginx>` -- /bin/bash

    Reemplaza `<nombre-del-pod-nginx>` con el nombre real del pod que obtuviste en el paso anterior.

8. Para ver los logs del pod de Nginx:

        kubectl logs `<nombre-del-pod-nginx>`

9. Para acceder a la aplicación Nginx desde tu navegador local, necesitarás configurar port-forwarding:

        kubectl port-forward service/nginx-service 8080:80

    hora puedes acceder a la aplicación Nginx en `http://localhost:8080` desde tu navegador local.

    Nota: Asegúrate de tener las credenciales de AWS configuradas correctamente en tu PC local para poder acceder al cluster EKS.

## Acceso a Kibana:

- Abrir un navegador web y acceda a la URL de Kibana proporcionada en el archivo `connection_info.txt`.

Verificar que Fluentd esté funcionando correctamente:
    kubectl get pods -n kube-system | grep fluentd
    kubectl logs -n kube-system -l k8s-app=fluentd-logging

Verificar que Elasticsearch esté recibiendo datos:
    kubectl exec -it $(kubectl get pods -l app=elasticsearch -o jsonpath='{.items[0].metadata.name}') -- curl -X GET "localhost:9200/_cat/indices?v"

### Configuración inicial de Kibana:

- En la página de inicio de Kibana, ir a "Stack Management" en el menú lateral.
- Clic en "Index Patterns" bajo la sección "Kibana".
- Clic en "Create index pattern".

### Creación del índice para los logs de Nginx:

- En el campo "Index pattern name", ingresar "logstash-*".
- Clic en "Next step".
- En "Time field", seleccionar "@timestamp".
- Clic en "Create index pattern".

### Visualización de logs:

- En el menú lateral de Kibana, ir a "Discover".
- Seleccionar el índice que se acaba de crear.
- Se ve una lista de logs recopilados por Fluentd de todos los pods, incluido el pod de Nginx.

### Filtrado de logs de Nginx:

- En la barra de búsqueda en la parte superior, ingresar `kubernetes.container_name: nginx` para filtrar solo los logs del pod de Nginx.

### Creación de un dashboard para Nginx:

- Ir a "Dashboard" en el menú lateral y hacer clic en "Create dashboard".
- Clic en "Create visualization".
- Seleccionar "Lens" para crear una visualización fácilmente.
- Arrastrar el campo "log" al área de visualización para ver un resumen de los logs.
- Guardar la visualización y añádirla al dashboard.

### Configuración de alertas (opcional):

- Ir a "Stack Management" > "Rules and Connectors".
- Crear una nueva regla basada en los logs de Nginx para recibir alertas sobre eventos específicos.

## Configuración y uso de Grafana con Prometheus para monitoreo del cloud y los pods

1. Acceso a Grafana:

1. Abra un navegador web y acceda a la URL de Grafana proporcionada en el archivo `connection_info.txt`.
2. Inicie sesión con las credenciales predeterminadas (usuario: admin, contraseña: admin).
3. Cambie la contraseña cuando se le solicite.

### Configuración de Prometheus como fuente de datos:

1. En el menú lateral de Grafana, vaya a "Configuration" > "Data Sources".
2. Haga clic en "Add data source" y seleccione "Prometheus".
3. En el campo "URL", ingrese la URL de Prometheus (http://`<EC2_IP>`:8080).
4. Haga clic en "Save & Test" para verificar la conexión.

### Importación de dashboards predefinidos:

1. En el menú lateral, vaya a "Create" > "Import".
2. Ingrese el ID 3119 para importar un dashboard de Kubernetes cluster monitoring.
3. Seleccione Prometheus como la fuente de datos y haga clic en "Import".

### Creación de un dashboard personalizado para el pod de Nginx:

1. Vaya a "Create" > "Dashboard".
2. Haga clic en "Add new panel".
3. En la consulta, use métricas como `container_cpu_usage_seconds_total{container="nginx"}` para CPU o `container_memory_usage_bytes{container="nginx"}` para memoria.
4. Ajuste el panel según sus necesidades y guárdelo.

### Configuración de alertas para el pod de Nginx:

1. En el panel que creó, vaya a la pestaña "Alert".
2. Configure una alerta basada en umbrales, por ejemplo, si el uso de CPU supera cierto porcentaje.
3. Especifique las condiciones de la alerta y guarde la configuración.

### Monitoreo del cloud (nodos de Kubernetes):

1. Importe el dashboard con ID 315 para monitoreo de nodos de Kubernetes.
2. Este dashboard proporcionará información sobre el uso de recursos a nivel de nodo.

### Configuración de la retención de datos:

1. En la instancia EC2, edite el archivo de configuración de Prometheus (`/etc/prometheus/prometheus.yml`).
2. Agregue o modifique la línea `storage.tsdb.retention.time: 15d` para establecer la retención de datos a 15 días (ajuste según sus necesidades).

### Exploración de métricas:

1. Use el explorador de métricas de Grafana para descubrir y graficar métricas adicionales específicas de su aplicación y entorno.

### Configuración de notificaciones:

1. En Grafana, vaya a "Alerting" > "Notification channels".
2. Configure canales de notificación como email, Slack, o PagerDuty para recibir alertas.

## Limpieza de recursos en AWS

Para limpiar todos los recursos generados en AWS, ejecuta los siguientes comandos:

1. Eliminar el cluster EKS:

    eksctl delete cluster --name cluster-PIN --region us-east-1


2. Eliminar el stack de CloudFormation:

    aws cloudformation delete-stack --stack-name jenkins-ec2-stack --region us-east-1

3. Esperar a que se complete la eliminación del stack:

    aws cloudformation wait stack-delete-complete --stack-name jenkins-ec2-stack --region us-east-1

4. Eliminar el key pair:

    aws ec2 delete-key-pair --key-name jenkins --region us-east-1

5. Verificar y eliminar cualquier volumen EBS huérfano:

    aws ec2 describe-volumes --filters Name=status,Values=available --query "Volumes[*