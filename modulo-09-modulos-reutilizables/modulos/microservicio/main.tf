# ============================================================
# MÓDULO REUTILIZABLE: Microservicio completo
# ============================================================
# Este módulo encapsula la creación de un "microservicio":
#   - Cola SQS (entrada)
#   - Cola DLQ (errores)
#   - Topic SNS (salida / eventos)
#   - Parámetros SSM (configuración)
#
# Se usa desde el main.tf del módulo 09 como:
#   module "mi_servicio" {
#     source = "./modulos/microservicio"
#     nombre = "pagos"
#     ...
#   }
# ============================================================

# --------------------------------------------------
# VARIABLES DEL MÓDULO (interfaz de entrada)
# --------------------------------------------------
variable "nombre" {
  description = "Nombre del microservicio"
  type        = string
}

variable "entorno" {
  description = "Entorno (dev, staging, prod)"
  type        = string
}

variable "max_reintentos" {
  description = "Máximo de reintentos antes de enviar a DLQ"
  type        = number
  default     = 3
}

variable "retencion_mensajes_horas" {
  description = "Horas de retención de mensajes"
  type        = number
  default     = 24
}

variable "tags" {
  description = "Tags comunes"
  type        = map(string)
  default     = {}
}

# --------------------------------------------------
# LOCALS
# --------------------------------------------------
locals {
  prefijo = "${var.entorno}-${var.nombre}"
  tags_modulo = merge(var.tags, {
    microservicio = var.nombre
    modulo        = "microservicio"
  })
}

# --------------------------------------------------
# RECURSOS
# --------------------------------------------------

# DLQ para mensajes fallidos
resource "aws_sqs_queue" "dlq" {
  name                      = "${local.prefijo}-dlq"
  message_retention_seconds = var.retencion_mensajes_horas * 3600 * 7  # DLQ retiene 7x más

  tags = local.tags_modulo
}

# Cola principal de entrada
resource "aws_sqs_queue" "entrada" {
  name                       = "${local.prefijo}-entrada"
  visibility_timeout_seconds = 60
  message_retention_seconds  = var.retencion_mensajes_horas * 3600

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_reintentos
  })

  tags = local.tags_modulo
}

# Topic SNS para eventos de salida
resource "aws_sns_topic" "eventos" {
  name = "${local.prefijo}-eventos"
  tags = local.tags_modulo
}

# Parámetros de configuración en SSM
resource "aws_ssm_parameter" "config" {
  name = "/${var.entorno}/servicios/${var.nombre}/config"
  type = "String"
  value = jsonencode({
    nombre          = var.nombre
    entorno         = var.entorno
    cola_entrada    = aws_sqs_queue.entrada.id
    cola_dlq        = aws_sqs_queue.dlq.id
    topic_eventos   = aws_sns_topic.eventos.arn
    max_reintentos  = var.max_reintentos
  })

  tags = local.tags_modulo
}

# --------------------------------------------------
# OUTPUTS DEL MÓDULO (interfaz de salida)
# --------------------------------------------------
output "cola_entrada_url" {
  description = "URL de la cola de entrada"
  value       = aws_sqs_queue.entrada.id
}

output "cola_entrada_arn" {
  description = "ARN de la cola de entrada"
  value       = aws_sqs_queue.entrada.arn
}

output "cola_dlq_arn" {
  description = "ARN de la DLQ"
  value       = aws_sqs_queue.dlq.arn
}

output "topic_eventos_arn" {
  description = "ARN del topic de eventos"
  value       = aws_sns_topic.eventos.arn
}

output "config_parameter_name" {
  description = "Nombre del parámetro SSM de configuración"
  value       = aws_ssm_parameter.config.name
}
