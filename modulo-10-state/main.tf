# ============================================================
# MÓDULO 10: STATE MANAGEMENT Y BACKENDS
# ============================================================
# Aprenderás:
#   - ¿Qué es el terraform state?
#   - Backend local vs remoto
#   - Backend S3 (usando LocalStack)
#   - State locking con DynamoDB
#   - Comandos de state: list, show, mv, rm, pull, push
#   - terraform import
#   - terraform workspace
#   - Moved blocks (refactoring)
#
# IMPORTANTE: Este módulo tiene dos pasos:
#   1. Primero: terraform apply en "paso-1-backend/"
#      (Crea el bucket S3 y tabla DynamoDB para el backend)
#   2. Después: terraform apply en este directorio
#      (Usa el backend S3 remoto)
#
# Comandos:
#   cd modulo-10-state/paso-1-backend
#   terraform init && terraform apply -auto-approve
#   cd ..
#   terraform init && terraform apply -auto-approve
# ============================================================

# --------------------------------------------------
# BACKEND S3 (almacenar state en S3 + locking en DynamoDB)
# --------------------------------------------------
# NOTA: El backend S3 con LocalStack requiere configuración especial.
# Si falla, puedes comentar el bloque backend y usar state local.
terraform {
  required_version = ">= 1.0.0"

  # Backend remoto en S3 (creado en paso-1-backend)
  # Descomenta esto después de ejecutar paso-1-backend:
  #
  # backend "s3" {
  #   bucket         = "lab-terraform-state"
  #   key            = "modulo-10/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "lab-terraform-locks"
  #
  #   # Configuración para LocalStack
  #   endpoint                    = "http://localhost:4566"
  #   skip_credentials_validation = true
  #   skip_metadata_api_check     = true
  #   force_path_style            = true
  #   access_key                  = "test"
  #   secret_key                  = "test"
  # }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    s3       = "http://localhost:4566"
    dynamodb = "http://localhost:4566"
    sqs      = "http://localhost:4566"
    ssm      = "http://localhost:4566"
    sts      = "http://localhost:4566"
  }
}

variable "entorno" {
  type    = string
  default = "dev"
}

locals {
  prefijo = "lab-${var.entorno}"
  tags = {
    proyecto = "estudio-terraform"
    modulo   = "10-state"
  }
}

# --------------------------------------------------
# RECURSOS PARA PRACTICAR STATE MANAGEMENT
# --------------------------------------------------

resource "aws_sqs_queue" "ejemplo_state" {
  name = "${local.prefijo}-state-demo"
  tags = local.tags
}

resource "aws_ssm_parameter" "ejemplo_state" {
  name  = "/${local.prefijo}/state-demo/version"
  type  = "String"
  value = "1.0.0"
  tags  = local.tags
}

# Recurso que vamos a "mover" en el state
resource "aws_ssm_parameter" "recurso_a_mover" {
  name  = "/${local.prefijo}/state-demo/movible"
  type  = "String"
  value = "Este recurso será movido en el state"
  tags  = local.tags
}

# --------------------------------------------------
# MOVED BLOCK (Terraform 1.1+)
# --------------------------------------------------
# El moved block permite renombrar/refactorizar recursos
# sin destruir y recrear. Descomenta para practicar:
#
# moved {
#   from = aws_ssm_parameter.recurso_a_mover
#   to   = aws_ssm_parameter.recurso_movido
# }
#
# resource "aws_ssm_parameter" "recurso_movido" {
#   name  = "/${local.prefijo}/state-demo/movible"
#   type  = "String"
#   value = "Este recurso fue movido en el state"
#   tags  = local.tags
# }

# --------------------------------------------------
# OUTPUTS
# --------------------------------------------------
output "cola_arn" {
  value = aws_sqs_queue.ejemplo_state.arn
}

output "parametro_name" {
  value = aws_ssm_parameter.ejemplo_state.name
}

output "guia_comandos_state" {
  description = "Comandos para practicar con el state"
  value       = <<-EOF

    === COMANDOS DE STATE PARA PRACTICAR ===

    # Ver todos los recursos en el state:
    terraform state list

    # Ver detalle de un recurso:
    terraform state show aws_sqs_queue.ejemplo_state

    # Mover un recurso en el state (renombrar):
    terraform state mv aws_ssm_parameter.recurso_a_mover aws_ssm_parameter.recurso_movido

    # Eliminar un recurso del state (SIN destruirlo):
    terraform state rm aws_ssm_parameter.ejemplo_state

    # Importar un recurso existente al state:
    terraform import aws_ssm_parameter.ejemplo_state /${local.prefijo}/state-demo/version

    # Ver el state completo en JSON:
    terraform show -json | python -m json.tool

    # Pull/Push del state (con backend remoto):
    terraform state pull > state_backup.json
    terraform state push state_backup.json

    === WORKSPACES ===

    # Listar workspaces:
    terraform workspace list

    # Crear nuevo workspace:
    terraform workspace new staging

    # Cambiar de workspace:
    terraform workspace select default

    # El workspace actual está en: terraform.workspace

  EOF
}

# --------------------------------------------------
# EJERCICIOS PROPUESTOS:
# --------------------------------------------------
# 1. Ejecuta todos los comandos de la guía de arriba.
#
# 2. Descomenta el bloque "moved" y haz terraform plan.
#    Verás que Terraform mueve el recurso sin destruirlo.
#
# 3. Crea un workspace "staging" y haz apply.
#    Observa que crea recursos independientes.
#
# 4. Haz "terraform state pull > backup.json" y examina el JSON.
#
# 5. Configura el backend S3:
#    a. Ejecuta paso-1-backend/
#    b. Descomenta el bloque backend
#    c. Ejecuta "terraform init -migrate-state"
#
# 6. Destruye un recurso manualmente y usa "terraform plan"
#    para ver cómo Terraform detecta el drift.
