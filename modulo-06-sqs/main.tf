# ============================================================
# MÓDULO 06: SQS - Colas de mensajes
# ============================================================
# Aprenderás:
#   - Colas estándar y FIFO
#   - Dead Letter Queues (DLQ)
#   - Políticas de acceso a colas
#   - Redrive policy (reintento de mensajes)
#   - Integración Lambda + SQS (event source mapping)
#   - Terraform functions: lookup, try, coalesce
#
# Comandos:
#   cd modulo-06-sqs
#   terraform init && terraform apply -auto-approve
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
    sqs    = "http://localhost:4566"
    sts    = "http://localhost:4566"
    iam    = "http://localhost:4566"
    lambda = "http://localhost:4566"
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
    modulo   = "06-sqs"
  }
}

# --------------------------------------------------
# COLA ESTÁNDAR SIMPLE
# --------------------------------------------------
resource "aws_sqs_queue" "principal" {
  name                       = "${local.prefijo}-cola-principal"
  delay_seconds              = 0              # Retraso antes de que el mensaje sea visible
  max_message_size           = 262144         # 256 KB máximo
  message_retention_seconds  = 86400          # Retener por 1 día
  visibility_timeout_seconds = 30             # Tiempo para procesar antes de reencolar
  receive_wait_time_seconds  = 10             # Long polling (esperar por mensajes)

  tags = local.tags
}

# --------------------------------------------------
# DEAD LETTER QUEUE (DLQ)
# --------------------------------------------------
# La DLQ recibe mensajes que fallaron después de N intentos.
# Es un patrón muy común en arquitecturas de mensajería.

resource "aws_sqs_queue" "dlq" {
  name                      = "${local.prefijo}-cola-dlq"
  message_retention_seconds = 604800  # 7 días (más tiempo para investigar fallos)

  tags = merge(local.tags, { tipo = "dead-letter-queue" })
}

# --------------------------------------------------
# COLA CON REDRIVE POLICY (apunta a la DLQ)
# --------------------------------------------------
resource "aws_sqs_queue" "procesamiento" {
  name                       = "${local.prefijo}-cola-procesamiento"
  visibility_timeout_seconds = 60

  # Redrive policy: después de 3 intentos fallidos, enviar a la DLQ
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })

  tags = local.tags
}

# --------------------------------------------------
# COLA FIFO (First In, First Out)
# --------------------------------------------------
# Las colas FIFO garantizan orden y exactly-once delivery.
# El nombre DEBE terminar en .fifo
resource "aws_sqs_queue" "fifo" {
  name                        = "${local.prefijo}-cola-ordenada.fifo"
  fifo_queue                  = true
  content_based_deduplication = true  # Deduplicar por contenido

  tags = merge(local.tags, { tipo = "fifo" })
}

# --------------------------------------------------
# POLÍTICA DE ACCESO A LA COLA
# --------------------------------------------------
data "aws_iam_policy_document" "cola_policy" {
  statement {
    sid    = "PermitirEnvio"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.principal.arn]
  }
}

resource "aws_sqs_queue_policy" "principal" {
  queue_url = aws_sqs_queue.principal.id
  policy    = data.aws_iam_policy_document.cola_policy.json
}

# --------------------------------------------------
# MÚLTIPLES COLAS CON for_each Y CONFIGURACIÓN DINÁMICA
# --------------------------------------------------
variable "colas_config" {
  description = "Configuración de colas adicionales"
  type = map(object({
    delay_seconds     = number
    retention_seconds = number
    visibility        = number
    usar_dlq          = bool
  }))
  default = {
    "notificaciones" = {
      delay_seconds     = 0
      retention_seconds = 86400
      visibility        = 30
      usar_dlq          = true
    }
    "emails" = {
      delay_seconds     = 5
      retention_seconds = 172800
      visibility        = 60
      usar_dlq          = true
    }
    "analytics" = {
      delay_seconds     = 0
      retention_seconds = 43200
      visibility        = 120
      usar_dlq          = false
    }
  }
}

resource "aws_sqs_queue" "adicionales" {
  for_each = var.colas_config

  name                       = "${local.prefijo}-cola-${each.key}"
  delay_seconds              = each.value.delay_seconds
  message_retention_seconds  = each.value.retention_seconds
  visibility_timeout_seconds = each.value.visibility

  # Condicional: solo configurar redrive si usar_dlq es true
  redrive_policy = each.value.usar_dlq ? jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  }) : null

  tags = merge(local.tags, { cola = each.key })
}

# --------------------------------------------------
# OUTPUTS
# --------------------------------------------------
output "cola_principal_url" {
  value = aws_sqs_queue.principal.id
}

output "cola_principal_arn" {
  value = aws_sqs_queue.principal.arn
}

output "dlq_arn" {
  value = aws_sqs_queue.dlq.arn
}

output "cola_fifo_url" {
  value = aws_sqs_queue.fifo.id
}

output "colas_adicionales" {
  value = { for k, q in aws_sqs_queue.adicionales : k => {
    url = q.id
    arn = q.arn
  }}
}

output "total_colas" {
  description = "Número total de colas creadas"
  value       = 4 + length(var.colas_config)  # 4 fijas + dinámicas
}

output "comando_enviar_mensaje" {
  description = "Comando para enviar un mensaje a la cola principal"
  value       = "aws --endpoint-url=http://localhost:4566 sqs send-message --queue-url ${aws_sqs_queue.principal.id} --message-body '{\"test\": true}'"
}

# --------------------------------------------------
# EJERCICIOS PROPUESTOS:
# --------------------------------------------------
# 1. Agrega una nueva cola al mapa "colas_config".
#
# 2. Envía un mensaje a la cola con el comando del output.
#    Luego recíbelo con:
#    aws --endpoint-url=http://localhost:4566 sqs receive-message \
#      --queue-url <URL_DE_LA_COLA>
#
# 3. Cambia el maxReceiveCount de la redrive policy a 5.
#
# 4. Crea una cola FIFO adicional para "pagos".
#
# 5. Modifica la política de la cola para restringir el acceso
#    a un usuario específico (usa un ARN ficticio).
