# ============================================================
# MÓDULO 09: MÓDULOS REUTILIZABLES
# ============================================================
# Aprenderás:
#   - Crear y usar módulos propios
#   - Pasar variables a módulos
#   - Usar outputs de módulos
#   - Componer infraestructura con módulos
#   - Modules con count y for_each
#   - Compartir datos entre módulos
#
# Comandos:
#   cd modulo-09-modulos-reutilizables
#   terraform init && terraform plan
#   terraform apply -auto-approve
#   terraform state list (verás module.xxx.recurso)
# ============================================================

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
    sqs      = "http://localhost:4566"
    sns      = "http://localhost:4566"
    ssm      = "http://localhost:4566"
    sts      = "http://localhost:4566"
    dynamodb = "http://localhost:4566"
  }
}

variable "entorno" {
  type    = string
  default = "dev"
}

locals {
  tags_globales = {
    proyecto = "estudio-terraform"
    modulo   = "09-modulos"
    entorno  = var.entorno
  }
}

# --------------------------------------------------
# USO DE MÓDULOS: Microservicios
# --------------------------------------------------
# Cada module block crea una instancia independiente del módulo.
# Es como llamar a una función con diferentes argumentos.

module "servicio_pagos" {
  source = "./modulos/microservicio"

  nombre                   = "pagos"
  entorno                  = var.entorno
  max_reintentos           = 5      # Más reintentos para pagos
  retencion_mensajes_horas = 72     # Retener 3 días
  tags                     = local.tags_globales
}

module "servicio_notificaciones" {
  source = "./modulos/microservicio"

  nombre                   = "notificaciones"
  entorno                  = var.entorno
  max_reintentos           = 3
  retencion_mensajes_horas = 24
  tags                     = local.tags_globales
}

module "servicio_inventario" {
  source = "./modulos/microservicio"

  nombre                   = "inventario"
  entorno                  = var.entorno
  max_reintentos           = 3
  retencion_mensajes_horas = 48
  tags                     = local.tags_globales
}

# --------------------------------------------------
# MÓDULOS CON for_each (crear múltiples instancias)
# --------------------------------------------------
variable "microservicios" {
  description = "Mapa de microservicios a crear dinámicamente"
  type = map(object({
    max_reintentos = number
    retencion      = number
  }))
  default = {
    "usuarios" = {
      max_reintentos = 3
      retencion      = 24
    }
    "auditoria" = {
      max_reintentos = 10
      retencion      = 168    # 7 días
    }
    "analytics" = {
      max_reintentos = 2
      retencion      = 12
    }
  }
}

module "servicios_dinamicos" {
  source   = "./modulos/microservicio"
  for_each = var.microservicios

  nombre                   = each.key
  entorno                  = var.entorno
  max_reintentos           = each.value.max_reintentos
  retencion_mensajes_horas = each.value.retencion
  tags                     = local.tags_globales
}

# --------------------------------------------------
# USO DEL MÓDULO BUCKET SEGURO
# --------------------------------------------------
module "bucket_datos" {
  source = "./modulos/bucket-seguro"

  nombre    = "datos-principales"
  entorno   = var.entorno
  versionado = true
  tags      = local.tags_globales
}

module "bucket_backups" {
  source = "./modulos/bucket-seguro"

  nombre    = "backups"
  entorno   = var.entorno
  versionado = true
  tags      = local.tags_globales
}

module "bucket_temporal" {
  source = "./modulos/bucket-seguro"

  nombre     = "temporal"
  entorno    = var.entorno
  versionado = false  # No versionar archivos temporales
  tags       = local.tags_globales
}

# --------------------------------------------------
# CONECTAR MÓDULOS ENTRE SÍ
# --------------------------------------------------
# Los outputs de un módulo se usan como inputs de otro.
# Aquí suscribimos la cola de notificaciones al topic de pagos.

resource "aws_sns_topic_subscription" "pagos_a_notificaciones" {
  topic_arn = module.servicio_pagos.topic_eventos_arn
  protocol  = "sqs"
  endpoint  = module.servicio_notificaciones.cola_entrada_arn
}

# Guardar la configuración de todos los servicios en un bucket
resource "aws_s3_object" "servicios_config" {
  bucket = module.bucket_datos.bucket_id
  key    = "config/servicios.json"
  content = jsonencode({
    pagos = {
      cola     = module.servicio_pagos.cola_entrada_url
      eventos  = module.servicio_pagos.topic_eventos_arn
    }
    notificaciones = {
      cola     = module.servicio_notificaciones.cola_entrada_url
      eventos  = module.servicio_notificaciones.topic_eventos_arn
    }
    inventario = {
      cola     = module.servicio_inventario.cola_entrada_url
      eventos  = module.servicio_inventario.topic_eventos_arn
    }
    dinamicos = {
      for k, m in module.servicios_dinamicos : k => {
        cola    = m.cola_entrada_url
        eventos = m.topic_eventos_arn
      }
    }
  })
  content_type = "application/json"
}

# --------------------------------------------------
# OUTPUTS
# --------------------------------------------------
output "servicio_pagos" {
  value = {
    cola_entrada  = module.servicio_pagos.cola_entrada_url
    topic_eventos = module.servicio_pagos.topic_eventos_arn
    dlq           = module.servicio_pagos.cola_dlq_arn
  }
}

output "servicio_notificaciones" {
  value = {
    cola_entrada  = module.servicio_notificaciones.cola_entrada_url
    topic_eventos = module.servicio_notificaciones.topic_eventos_arn
  }
}

output "servicios_dinamicos" {
  value = {
    for k, m in module.servicios_dinamicos : k => {
      cola    = m.cola_entrada_url
      eventos = m.topic_eventos_arn
    }
  }
}

output "buckets" {
  value = {
    datos    = module.bucket_datos.bucket_nombre
    backups  = module.bucket_backups.bucket_nombre
    temporal = module.bucket_temporal.bucket_nombre
  }
}

output "total_microservicios" {
  value = 3 + length(var.microservicios)
}

# --------------------------------------------------
# EJERCICIOS PROPUESTOS:
# --------------------------------------------------
# 1. Agrega un nuevo microservicio "reportes" al mapa variable.
#
# 2. Crea un nuevo módulo reutilizable "tabla-dynamodb" en modulos/
#    que cree una tabla DynamoDB con hash_key configurable.
#
# 3. Suscribe el servicio de auditoría al topic de todos los servicios.
#
# 4. Usa "terraform state list" y observa cómo los recursos
#    aparecen con prefijo module.xxx.
#
# 5. Haz "terraform destroy -target=module.servicio_pagos"
#    ¿Qué pasa con la suscripción SNS→SQS?
