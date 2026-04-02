# Módulo 10 — Gestión del Estado (State)

## ¿Qué vas a aprender?

- Qué es el state de Terraform y por qué es crítico
- Cómo configurar un backend remoto en S3 + DynamoDB
- Cómo funciona el bloqueo de state (locking)
- El bloque `moved {}` para renombrar recursos sin re-crear
- Workspaces: múltiples entornos con un solo código
- Los comandos `terraform state` para administrar el state directamente
- El proceso de migración de backend en dos pasos

---

## Cómo ejecutar este módulo

```bash
docker-compose up -d

# PASO 1: Crear el bucket S3 y la tabla DynamoDB para el backend
cd modulo-10-state/paso-1-backend
terraform init
terraform apply -auto-approve

# PASO 2: Usar el backend remoto
cd ../
terraform init    # Te preguntará si migrar el state
terraform apply -auto-approve
terraform output
```

---

## ¿Qué es el State?

Terraform guarda en un archivo `terraform.tfstate` **todo lo que sabe** sobre la infraestructura que ha creado. Es su "memoria":

```json
{
  "resources": [
    {
      "type": "aws_sqs_queue",
      "name": "ejemplo_state",
      "instances": [{ "attributes": { "id": "https://...", "arn": "arn:aws:..." } }]
    }
  ]
}
```

Sin el state, Terraform no sabe qué ya existe y crearía todo de cero cada vez.

**El problema del state local:** Si el archivo `terraform.tfstate` vive en tu máquina y tu compañero ejecuta Terraform desde su máquina, hay dos states diferentes. La infraestructura queda inconsistente. Por eso el state debe ser **remoto y compartido**.

---

## Paso 1: Crear la infraestructura del backend

Antes de usar un backend remoto, necesitas el bucket S3 y la tabla DynamoDB. Esto se hace en un módulo separado (paso-1-backend):

```hcl
resource "aws_s3_bucket" "terraform_state" {
  bucket = "terraform-state-${var.entorno}"
}

resource "aws_s3_bucket_versioning" "state_versioning" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_dynamodb_table" "terraform_locks" {
  name         = "terraform-locks-${var.entorno}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"   # El tipo debe ser String
  }
}
```

La tabla DynamoDB necesita solo el atributo `LockID` de tipo string. Terraform lo usa para escribir un registro de bloqueo cuando alguien está ejecutando un `apply`.

---

## Paso 2: Configurar el backend remoto

Una vez creada la infraestructura del paso 1, configura el backend en el módulo principal:

```hcl
terraform {
  required_version = ">= 1.0.0"

  # ⚠️ DESCOMENTAR después de ejecutar el paso-1-backend
  backend "s3" {
    bucket         = "terraform-state-dev"
    key            = "modulo-10/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks-dev"

    # Para LocalStack
    endpoint                = "http://localhost:4566"
    access_key              = "test"
    secret_key              = "test"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    force_path_style            = true
  }
}
```

Cuando ejecutas `terraform init` con este backend configurado, Terraform:

1. Lee la configuración del backend
2. Si existe un state local, pregunta si quieres migrarlo al remoto
3. A partir de ese momento, guarda el state en S3

---

## Cómo funciona el locking

```
Desarrollador 1: terraform apply   →  Escribe "LockID" en DynamoDB
                                      Ejecuta el plan
                                      Borra "LockID" de DynamoDB

Desarrollador 2: terraform apply   →  Intenta escribir "LockID"...
(al mismo tiempo)                     DynamoDB ya tiene LockID
                                      ❌ Error: "state is locked"
```

El locking evita que dos personas modifiquen la infraestructura al mismo tiempo y corrompan el state.

---

## El bloque `moved {}`

Problema clásico: tienes un recurso llamado `aws_sqs_queue.ejemplo` y quieres renombrarlo a `aws_sqs_queue.ejemplo_state`. Sin `moved {}`, Terraform destruiría el primero y crearía el segundo. Con `moved {}`, solo actualiza el state:

```hcl
moved {
  from = aws_sqs_queue.ejemplo        # Nombre anterior
  to   = aws_sqs_queue.ejemplo_state  # Nombre nuevo
}

resource "aws_sqs_queue" "ejemplo_state" {
  name = "ejemplo-state-queue"
}
```

**Terraform entiende esto como:**

```
No te preocupes, aws_sqs_queue.ejemplo_state es el mismo recurso
que antes se llamaba aws_sqs_queue.ejemplo. No lo destruyas.
```

El `moved {}` también funciona para mover recursos dentro de/fuera de módulos:

```hcl
moved {
  from = aws_sqs_queue.estado
  to   = module.cola.aws_sqs_queue.principal
}
```

---

## Workspaces: múltiples entornos

Un workspace es como una "capa" de state separada. El mismo código puede generar infraestructura para `dev`, `staging` y `produccion` sin interferir:

```bash
terraform workspace list          # Ver workspaces disponibles
terraform workspace new staging   # Crear workspace "staging"
terraform workspace select dev    # Cambiar a workspace "dev"
terraform workspace show          # Ver workspace actual
```

En el código, puedes usar `terraform.workspace` para personalizar recursos por entorno:

```hcl
locals {
  config = {
    "default"    = { retencion = 900,   max_size = 262144  }
    "dev"        = { retencion = 900,   max_size = 262144  }
    "staging"    = { retencion = 3600,  max_size = 1048576 }
    "produccion" = { retencion = 86400, max_size = 1048576 }
  }

  config_actual = local.config[terraform.workspace]
}

resource "aws_sqs_queue" "por_entorno" {
  name                       = "cola-${terraform.workspace}"
  visibility_timeout_seconds = local.config_actual.retencion
  max_message_size           = local.config_actual.max_size
}
```

Cuando estás en el workspace `staging`, la cola se llama `cola-staging` con sus propios valores.

---

## Comandos `terraform state`

Estos comandos permiten administrar el state directamente:

```bash
# Ver todos los recursos en el state
terraform state list

# Ver detalles de un recurso específico
terraform state show aws_sqs_queue.ejemplo_state

# Mover un recurso (renombrar en el state sin re-crear)
terraform state mv aws_sqs_queue.viejo aws_sqs_queue.nuevo

# Eliminar un recurso del state (sin destruirlo en AWS)
# Útil para "dejar de gestionar" algo sin destruirlo
terraform state rm aws_sqs_queue.ejemplo_state

# Importar un recurso existente al state
# (adoptar infraestructura creada manualmente)
terraform import aws_sqs_queue.existente https://queue-url

# Descargar el state para inspección
terraform state pull > backup_state.json

# Subir un state modificado manualmente
terraform state push backup_state.json
```

**`terraform state rm` vs `terraform destroy`:**

- `terraform destroy`: elimina el recurso de AWS (lo destruye)
- `terraform state rm`: elimina el recurso del state pero lo deja en AWS (Terraform "lo olvida")

---

## Output de referencia rápida

Este módulo incluye un output con todos los comandos relevantes:

```hcl
output "guia_comandos" {
  value = {
    listar_recursos    = "terraform state list"
    ver_recurso        = "terraform state show aws_sqs_queue.ejemplo_state"
    mover_recurso      = "terraform state mv SOURCE DESTINATION"
    eliminar_del_state = "terraform state rm RESOURCE"
    descargar_state    = "terraform state pull"
  }
}
```

---

## Tabla resumen de backends

| Backend | Cuándo usar |
|---------|-------------|
| `local` | Solo en tu máquina, proyectos personales o aprendizaje |
| `s3` | Equipos en AWS. El más común en producción |
| `gcs` | Equipos en Google Cloud |
| `azurerm` | Equipos en Azure |
| `terraform cloud` | Servicio gestionado de HashiCorp |

---

## Ejercicios propuestos

1. Ejecuta los dos pasos y verifica que el state se guarda en S3 con: `aws --endpoint http://localhost:4566 s3 ls s3://terraform-state-dev/ --recursive`

2. Crea un workspace `staging`, ejecuta `terraform apply` y verifica que el state de staging se guarda con una key diferente en S3.

3. Renombra el recurso `aws_sqs_queue.ejemplo_state` a `aws_sqs_queue.cola_principal` usando el bloque `moved {}`. Ejecuta `terraform plan` y verifica que dice "0 to add, 0 to destroy".

4. Usa `terraform state pull` para ver el contenido completo del state en JSON.

5. Usa `terraform state rm aws_ssm_parameter.recurso_a_mover`. Luego ejecuta `terraform plan`. ¿Qué dice? ¿Por qué?
