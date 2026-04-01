# ============================================================
# MÓDULO 07: SNS - Servicio de Notificaciones
# ============================================================
# Aprenderás:
#   - Topics SNS (estándar y FIFO)
#   - Suscripciones (SQS, email, Lambda, HTTP)
#   - Fan-out pattern (un topic → múltiples suscriptores)
#   - Filtros de suscripción
#   - Integración SNS + SQS
#   - Terraform dynamic blocks
#
# Comandos:
#   cd modulo-07-sns
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
    sns = "http://localhost:4566"
    sqs = "http://localhost:4566"
    sts = "http://localhost:4566"
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
    modulo   = "07-sns"
  }
}

# --------------------------------------------------
# TOPIC SNS SIMPLE
# --------------------------------------------------
resource "aws_sns_topic" "alertas" {
  name = "${local.prefijo}-alertas"
  tags = local.tags
}

# --------------------------------------------------
# TOPIC FIFO
# --------------------------------------------------
resource "aws_sns_topic" "pedidos" {
  name                        = "${local.prefijo}-pedidos.fifo"
  fifo_topic                  = true
  content_based_deduplication = true

  tags = merge(local.tags, { tipo = "fifo" })
}

# --------------------------------------------------
# COLAS SQS (para suscribirlas al topic)
# --------------------------------------------------
resource "aws_sqs_queue" "email_queue" {
  name = "${local.prefijo}-sns-emails"
  tags = local.tags
}

resource "aws_sqs_queue" "sms_queue" {
  name = "${local.prefijo}-sns-sms"
  tags = local.tags
}

resource "aws_sqs_queue" "slack_queue" {
  name = "${local.prefijo}-sns-slack"
  tags = local.tags
}

# --------------------------------------------------
# SUSCRIPCIONES: Fan-out pattern
# --------------------------------------------------
# Un mismo topic puede notificar a múltiples suscriptores.
# Esto es el patrón "fan-out": un evento → múltiples destinos.

resource "aws_sns_topic_subscription" "alertas_to_email" {
  topic_arn = aws_sns_topic.alertas.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.email_queue.arn

  # Filtro: solo recibir alertas de tipo "email"
  filter_policy = jsonencode({
    tipo_alerta = ["email", "critico"]
  })
}

resource "aws_sns_topic_subscription" "alertas_to_sms" {
  topic_arn = aws_sns_topic.alertas.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.sms_queue.arn

  filter_policy = jsonencode({
    tipo_alerta = ["sms", "critico"]
    prioridad   = ["alta"]
  })
}

resource "aws_sns_topic_subscription" "alertas_to_slack" {
  topic_arn = aws_sns_topic.alertas.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.slack_queue.arn

  # Sin filtro: recibe TODO
}

# --------------------------------------------------
# POLÍTICA DEL TOPIC
# --------------------------------------------------
data "aws_iam_policy_document" "sns_policy" {
  statement {
    sid    = "PermitirPublicacion"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alertas.arn]
  }
}

resource "aws_sns_topic_policy" "alertas" {
  arn    = aws_sns_topic.alertas.arn
  policy = data.aws_iam_policy_document.sns_policy.json
}

# --------------------------------------------------
# MÚLTIPLES TOPICS CON for_each + dynamic blocks
# --------------------------------------------------
variable "topics_config" {
  type = map(object({
    nombre_display = string
    suscriptores   = list(string)
  }))
  default = {
    "errores" = {
      nombre_display = "Errores de aplicación"
      suscriptores   = ["equipo-backend", "equipo-ops"]
    }
    "despliegues" = {
      nombre_display = "Notificaciones de despliegue"
      suscriptores   = ["equipo-devops"]
    }
    "seguridad" = {
      nombre_display = "Alertas de seguridad"
      suscriptores   = ["equipo-seguridad", "equipo-ops"]
    }
  }
}

resource "aws_sns_topic" "dinamicos" {
  for_each = var.topics_config

  name         = "${local.prefijo}-${each.key}"
  display_name = each.value.nombre_display

  tags = merge(local.tags, {
    topic       = each.key
    suscriptores = join(",", each.value.suscriptores)
  })
}

# Colas para los suscriptores dinámicos
locals {
  # Flatten: convertir estructura anidada en lista plana
  suscripciones = flatten([
    for topic_key, topic_config in var.topics_config : [
      for suscriptor in topic_config.suscriptores : {
        topic_key  = topic_key
        suscriptor = suscriptor
        key        = "${topic_key}-${suscriptor}"
      }
    ]
  ])

  # Convertir a mapa para for_each
  suscripciones_map = { for s in local.suscripciones : s.key => s }
}

resource "aws_sqs_queue" "suscriptores" {
  for_each = local.suscripciones_map

  name = "${local.prefijo}-${each.key}"
  tags = merge(local.tags, {
    topic      = each.value.topic_key
    suscriptor = each.value.suscriptor
  })
}

resource "aws_sns_topic_subscription" "dinamicas" {
  for_each = local.suscripciones_map

  topic_arn = aws_sns_topic.dinamicos[each.value.topic_key].arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.suscriptores[each.key].arn
}

# --------------------------------------------------
# OUTPUTS
# --------------------------------------------------
output "topic_alertas_arn" {
  value = aws_sns_topic.alertas.arn
}

output "topics_dinamicos" {
  value = { for k, t in aws_sns_topic.dinamicos : k => t.arn }
}

output "suscripciones_creadas" {
  value = { for k, s in aws_sns_topic_subscription.dinamicas : k => {
    topic    = s.topic_arn
    endpoint = s.endpoint
  }}
}

output "total_suscripciones" {
  value = length(local.suscripciones_map) + 3  # dinámicas + 3 fijas
}

output "comando_publicar" {
  value = "aws --endpoint-url=http://localhost:4566 sns publish --topic-arn ${aws_sns_topic.alertas.arn} --message '{\"alerta\": \"test\"}' --message-attributes '{\"tipo_alerta\": {\"DataType\": \"String\", \"StringValue\": \"email\"}}'"
}

# --------------------------------------------------
# EJERCICIOS PROPUESTOS:
# --------------------------------------------------
# 1. Publica un mensaje con el comando del output y verifica
#    que llega a la cola correcta según el filtro.
#
# 2. Agrega un nuevo topic "metricas" al mapa topics_config.
#
# 3. Modifica un filter_policy para que solo acepte prioridad "alta".
#
# 4. Crea un topic FIFO adicional para "transacciones".
#
# 5. Implementa el patrón inverso: una cola que recibe de múltiples topics.
