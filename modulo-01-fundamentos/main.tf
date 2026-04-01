# ============================================================
# MÓDULO 01: FUNDAMENTOS BÁSICOS DE TERRAFORM
# ============================================================
# Aprenderás:
#   - Estructura de un archivo Terraform
#   - Variables (input variables)
#   - Variables locales (locals)
#   - Outputs
#   - Tipos de datos (string, number, bool, list, map)
#   - Interpolación de strings
#   - Condicionales y ciclos básicos
#
# Comandos a practicar:
#   cd modulo-01-fundamentos
#   terraform init
#   terraform plan
#   terraform apply
#   terraform output
#   terraform destroy
# ============================================================

# --------------------------------------------------
# PROVIDER: Configuración para apuntar a LocalStack
# --------------------------------------------------
terraform {
  required_version = ">= 1.0.0"

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
    iam      = "http://localhost:4566"
    lambda   = "http://localhost:4566"
    sqs      = "http://localhost:4566"
    sns      = "http://localhost:4566"
    ec2      = "http://localhost:4566"
    sts      = "http://localhost:4566"
    ssm      = "http://localhost:4566"
  }
}

# --------------------------------------------------
# VARIABLES DE ENTRADA (Input Variables)
# --------------------------------------------------
# Las variables permiten parametrizar tu infraestructura.
# Se pueden pasar con: -var, -var-file, terraform.tfvars, o variables de entorno.

variable "proyecto" {
  description = "Nombre del proyecto"
  type        = string
  default     = "mi-lab-terraform"
}

variable "entorno" {
  description = "Entorno de despliegue"
  type        = string
  default     = "desarrollo"

  # Validación: solo permite ciertos valores
  validation {
    condition     = contains(["desarrollo", "staging", "produccion"], var.entorno)
    error_message = "El entorno debe ser: desarrollo, staging o produccion."
  }
}

variable "numero_de_buckets" {
  description = "Cuántos buckets S3 crear"
  type        = number
  default     = 2
}

variable "habilitar_logs" {
  description = "¿Habilitar logging?"
  type        = bool
  default     = true
}

variable "tags_comunes" {
  description = "Tags comunes para todos los recursos"
  type        = map(string)
  default = {
    "proyecto"   = "estudio-terraform"
    "creado_por" = "terraform"
    "entorno"    = "local"
  }
}

variable "zonas_disponibles" {
  description = "Lista de zonas de disponibilidad"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

# --------------------------------------------------
# VARIABLES LOCALES (Locals)
# --------------------------------------------------
# Los locals son variables calculadas que no se exponen al usuario.
# Útiles para evitar repetición y centralizar lógica.

locals {
  # Interpolación de strings
  nombre_completo = "${var.proyecto}-${var.entorno}"

  # Condicional (operador ternario)
  nivel_logs = var.habilitar_logs ? "INFO" : "NONE"

  # Merge de maps
  tags_finales = merge(var.tags_comunes, {
    "nombre" = local.nombre_completo
    "fecha"  = timestamp()
  })

  # Transformar lista a mapa
  zonas_map = { for idx, zona in var.zonas_disponibles : "zona-${idx}" => zona }
}

# --------------------------------------------------
# RECURSOS: Creamos SSM Parameters (almacén de config)
# --------------------------------------------------
# SSM Parameter Store es un servicio key-value de AWS.
# Perfecto para aprender porque es simple y visible.

resource "aws_ssm_parameter" "configuracion_proyecto" {
  name  = "/${local.nombre_completo}/config/nombre"
  type  = "String"
  value = local.nombre_completo

  tags = local.tags_finales
}

resource "aws_ssm_parameter" "configuracion_entorno" {
  name  = "/${local.nombre_completo}/config/entorno"
  type  = "String"
  value = var.entorno

  tags = local.tags_finales
}

resource "aws_ssm_parameter" "configuracion_logs" {
  name  = "/${local.nombre_completo}/config/nivel-logs"
  type  = "String"
  value = local.nivel_logs

  tags = local.tags_finales
}

# --------------------------------------------------
# RECURSO CON count (crear múltiples instancias)
# --------------------------------------------------
resource "aws_ssm_parameter" "parametros_zonas" {
  count = length(var.zonas_disponibles)

  name  = "/${local.nombre_completo}/zonas/zona-${count.index}"
  type  = "String"
  value = var.zonas_disponibles[count.index]

  tags = local.tags_finales
}

# --------------------------------------------------
# RECURSO CON for_each (crear instancias desde un mapa)
# --------------------------------------------------
resource "aws_ssm_parameter" "tags_individuales" {
  for_each = var.tags_comunes

  name  = "/${local.nombre_completo}/tags/${each.key}"
  type  = "String"
  value = each.value

  tags = local.tags_finales
}

# --------------------------------------------------
# OUTPUTS (Valores de salida)
# --------------------------------------------------
# Los outputs muestran información después de terraform apply.
# También sirven para compartir datos entre módulos.

output "nombre_proyecto" {
  description = "Nombre completo del proyecto"
  value       = local.nombre_completo
}

output "nivel_logs" {
  description = "Nivel de logs configurado"
  value       = local.nivel_logs
}

output "zonas_map" {
  description = "Mapa de zonas de disponibilidad"
  value       = local.zonas_map
}

output "parametros_creados" {
  description = "Lista de parámetros SSM creados"
  value = [
    aws_ssm_parameter.configuracion_proyecto.name,
    aws_ssm_parameter.configuracion_entorno.name,
    aws_ssm_parameter.configuracion_logs.name,
  ]
}

output "parametros_zonas" {
  description = "Parámetros de zonas creados con count"
  value       = [for p in aws_ssm_parameter.parametros_zonas : p.name]
}

output "parametros_tags" {
  description = "Parámetros de tags creados con for_each"
  value       = { for k, p in aws_ssm_parameter.tags_individuales : k => p.name }
}

# --------------------------------------------------
# EJERCICIOS PROPUESTOS:
# --------------------------------------------------
# 1. Cambia el valor de "entorno" a "staging" y haz terraform plan
#    ¿Qué recursos cambian?
#
# 2. Añade una nueva variable "version" de tipo string con default "1.0.0"
#    y crea un nuevo aws_ssm_parameter que la use.
#
# 3. Cambia "numero_de_buckets" a 5 y observa qué pasa con terraform plan.
#
# 4. Crea un output que muestre el número total de parámetros creados.
#
# 5. Usa "terraform state list" para ver todos los recursos en el state.
#
# 6. Usa "terraform show" para ver el estado completo.
#
# 7. Usa "terraform output -json" para ver los outputs en formato JSON.
