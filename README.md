# 🏗️ Laboratorio de Terraform con LocalStack

Entorno completo para aprender Terraform **sin necesitar cuenta de AWS**. Usa [LocalStack](https://localstack.cloud/) para simular servicios AWS en tu máquina local.

## 📋 Requisitos previos

| Herramienta | Instalación |
|-------------|-------------|
| **Docker Desktop** | [docker.com/get-docker](https://docs.docker.com/get-docker/) |
| **Terraform** (>= 1.0) | [terraform.io/downloads](https://developer.hashicorp.com/terraform/downloads) |
| **AWS CLI** (opcional) | [aws.amazon.com/cli](https://aws.amazon.com/cli/) |

## 🚀 Inicio rápido

### 1. Levantar LocalStack

```bash
# Desde la raíz del proyecto
docker-compose up -d

# Verificar que está corriendo
curl http://localhost:4566/_localstack/health
```

### 2. Configurar AWS CLI para LocalStack (opcional, pero útil)

```bash
# Crear perfil "localstack" en AWS CLI
aws configure --profile localstack
# Access Key: test
# Secret Key: test
# Region: us-east-1
# Output: json

# Alias útil para no repetir --endpoint-url
# En PowerShell:
function awslocal { aws --endpoint-url=http://localhost:4566 @args }

# En Bash/WSL:
alias awslocal='aws --endpoint-url=http://localhost:4566'
```

### 3. Ejecutar tu primer módulo

```bash
cd modulo-01-fundamentos
terraform init      # Descarga providers
terraform plan      # Vista previa de cambios
terraform apply     # Crear recursos (confirmar con "yes")
terraform output    # Ver valores de salida
terraform destroy   # Eliminar todo
```

## 📚 Módulos de estudio (orden recomendado)

| # | Módulo | Temas | Dificultad |
|---|--------|-------|------------|
| 01 | **Fundamentos** | Variables, locals, outputs, tipos de datos, count, for_each | ⭐ |
| 02 | **S3 Buckets** | Almacenamiento, versionado, website, objetos, data sources | ⭐ |
| 03 | **DynamoDB** | Tablas NoSQL, GSI, LSI, capacity modes, table items | ⭐⭐ |
| 04 | **IAM** | Roles, políticas, usuarios, grupos, policy documents | ⭐⭐ |
| 05 | **Lambda** | Funciones serverless, empaquetado, logs, lifecycle | ⭐⭐ |
| 06 | **SQS** | Colas de mensajes, DLQ, FIFO, redrive policy | ⭐⭐ |
| 07 | **SNS** | Topics, suscripciones, fan-out, filtros, flatten | ⭐⭐⭐ |
| 08 | **VPC** | Redes, subnets, gateways, security groups, cidrsubnet | ⭐⭐⭐ |
| 09 | **Módulos** | Módulos reutilizables, composición, for_each en modules | ⭐⭐⭐ |
| 10 | **State** | State management, backends S3, locking, workspaces, import | ⭐⭐⭐⭐ |
| 11 | **Escalamiento Vertical** | ALB, NLB, target groups, listener rules, instancias EC2 por tamaño | ⭐⭐⭐ |
| 12 | **Escalamiento Horizontal** | ASG, launch templates, scaling policies, CloudWatch alarms | ⭐⭐⭐⭐ |
| 13 | **Cache** | ElastiCache Redis, Memcached, replication groups, parameter groups | ⭐⭐⭐ |
| 14 | **Segmentación de Redes** | Multi-VPC, VPC Peering, NACLs, VPC Endpoints, Flow Logs | ⭐⭐⭐⭐ |
| 15 | **CI/CD y GitOps** | Pipelines, GitOps, state remoto, roles, flujo de PR | ⭐⭐⭐⭐ |
| 16 | **Backup y DR** | S3 versioning, replication, PITR, lifecycle, estrategias DR | ⭐⭐⭐ |
| 17 | **Costos y Tagging** | Tags, presupuestos, right-sizing, alertas, pricing models | ⭐⭐⭐ |

## 🔧 Comandos esenciales de Terraform

```bash
# === FLUJO BÁSICO ===
terraform init              # Inicializar (descargar providers)
terraform plan              # Ver qué cambios se harán
terraform apply             # Aplicar cambios
terraform destroy           # Destruir todos los recursos

# === INSPECCIÓN ===
terraform show              # Ver el state actual
terraform output            # Ver outputs
terraform output -json      # Outputs en JSON
terraform state list        # Listar recursos en el state
terraform state show <rec>  # Detalle de un recurso

# === AVANZADO ===
terraform plan -out=plan.tfplan     # Guardar plan
terraform apply plan.tfplan          # Aplicar plan guardado
terraform apply -auto-approve        # Sin confirmación
terraform apply -target=<recurso>    # Solo un recurso
terraform destroy -target=<recurso>  # Destruir solo uno

# === STATE MANAGEMENT ===
terraform state mv <orig> <dest>    # Mover/renombrar en state
terraform state rm <recurso>        # Quitar del state (no destruye)
terraform import <recurso> <id>     # Importar recurso existente
terraform state pull                # Descargar state (backend remoto)

# === WORKSPACES ===
terraform workspace list            # Listar workspaces
terraform workspace new staging     # Crear workspace
terraform workspace select default  # Cambiar workspace

# === FORMATO Y VALIDACIÓN ===
terraform fmt                       # Formatear código
terraform fmt -check                # Verificar formato
terraform validate                  # Validar sintaxis

# === DEBUGGING ===
terraform graph                     # Grafo de dependencias (formato DOT)
TF_LOG=DEBUG terraform plan         # Log detallado
terraform console                   # Consola interactiva
```

## 🧪 Verificar recursos con AWS CLI

```bash
# Listar buckets S3
aws --endpoint-url=http://localhost:4566 s3 ls

# Listar tablas DynamoDB
aws --endpoint-url=http://localhost:4566 dynamodb list-tables

# Listar colas SQS
aws --endpoint-url=http://localhost:4566 sqs list-queues

# Listar topics SNS
aws --endpoint-url=http://localhost:4566 sns list-topics

# Listar funciones Lambda
aws --endpoint-url=http://localhost:4566 lambda list-functions

# Invocar Lambda
aws --endpoint-url=http://localhost:4566 lambda invoke \
  --function-name lab-dev-hello-world \
  --payload '{"test": true}' /dev/stdout

# Enviar mensaje a SQS
aws --endpoint-url=http://localhost:4566 sqs send-message \
  --queue-url http://localhost:4566/000000000000/lab-dev-cola-principal \
  --message-body '{"orden": "12345"}'
```

## 📁 Estructura del proyecto

```
estudio-terraform/
├── docker-compose.yml              # LocalStack
├── README.md                       # Esta guía
├── .gitignore
├── modulo-01-fundamentos/
│   └── main.tf                     # Variables, locals, outputs
├── modulo-02-s3/
│   └── main.tf                     # Buckets, objetos, website
├── modulo-03-dynamodb/
│   └── main.tf                     # Tablas, GSI, items
├── modulo-04-iam/
│   └── main.tf                     # Roles, políticas, usuarios
├── modulo-05-lambda/
│   ├── main.tf                     # Funciones Lambda
│   └── src/
│       ├── index.py                # Código Lambda
│       └── procesador.py           # Procesador SQS
├── modulo-06-sqs/
│   └── main.tf                     # Colas, DLQ, FIFO
├── modulo-07-sns/
│   └── main.tf                     # Topics, suscripciones, fan-out
├── modulo-08-vpc/
│   └── main.tf                     # VPC, subnets, security groups
├── modulo-09-modulos-reutilizables/
│   ├── main.tf                     # Usa módulos propios
│   └── modulos/
│       ├── microservicio/main.tf   # Módulo: microservicio
│       └── bucket-seguro/main.tf   # Módulo: bucket S3
├── modulo-10-state/
│   ├── main.tf                     # State management
│   └── paso-1-backend/
│       └── main.tf                 # Crear backend S3
├── modulo-11-escalamiento-vertical/
│   └── main.tf                     # ALB, NLB, target groups
├── modulo-12-escalamiento-horizontal/
│   └── main.tf                     # ASG, scaling policies
├── modulo-13-cache/
│   └── main.tf                     # ElastiCache Redis, Memcached
├── modulo-14-segmentacion-redes/
│   └── main.tf                     # Multi-VPC, peering, NACLs
├── modulo-15-cicd-gitops/
│   ├── main.tf                     # GitOps, state remoto, roles pipeline
│   └── pipelines/
│       ├── github-actions.yml      # Ejemplo pipeline GitHub Actions
│       └── gitlab-ci.yml           # Ejemplo pipeline GitLab CI
├── modulo-16-backup-dr/
│   └── main.tf                     # Backup, DR, S3 lifecycle, PITR
└── modulo-17-costos-tagging/
    └── main.tf                     # Tags, presupuestos, sizing
```

## 💡 Tips de estudio

1. **Sigue el orden**: Los módulos van de básico a avanzado.
2. **Lee los comentarios**: Cada archivo tiene explicaciones detalladas.
3. **Experimenta**: Modifica valores, agrega recursos, rompe cosas a propósito.
4. **Usa `terraform plan`**: Siempre antes de `apply` para entender los cambios.
5. **Haz los ejercicios**: Al final de cada módulo hay ejercicios propuestos.
6. **Usa `terraform console`**: Para probar expresiones y funciones.
7. **Destruye y recrea**: `terraform destroy` y `apply` son baratos con LocalStack.

## ⚠️ Solución de problemas

| Problema | Solución |
|----------|----------|
| LocalStack no responde | `docker-compose down && docker-compose up -d` |
| Error de credenciales | Las credenciales son "test"/"test" fijas |
| Puerto 4566 en uso | Cambiar el puerto en docker-compose.yml |
| terraform init falla | Verificar conexión a Internet (descarga providers) |
| Recurso ya existe | `terraform destroy` o cambiar nombres |

## 🛑 Detener LocalStack

```bash
docker-compose down       # Detener (pierde datos)
docker-compose stop       # Pausar (mantiene datos)
```
