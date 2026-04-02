# Módulo 07 — SNS · Servicio de Notificaciones

## ¿Qué vas a aprender?

- Qué es SNS y cómo funciona el modelo pub/sub
- Crear topics SNS estándar y FIFO
- Suscribir colas SQS a un topic (patrón fan-out)
- Filtrar qué mensajes recibe cada suscriptor
- Crear múltiples topics y suscripciones dinámicamente
- Usar `flatten` para "aplanar" listas de listas
- Convertir estructuras anidadas a mapas con `for_each`

---

## Cómo ejecutar este módulo

```bash
docker-compose up -d
cd modulo-07-sns
terraform init
terraform apply -auto-approve
terraform output
terraform destroy
```

---

## Concepto previo — SQS vs SNS

Ya conoces SQS (colas punto a punto). SNS es diferente:

```
SQS — uno a uno (cola):
  Servicio A  →  Cola  →  Servicio B

SNS — uno a muchos (topic):
  Servicio A  →  Topic SNS  →  Servicio B (email)
                             →  Servicio C (SMS)
                             →  Servicio D (logs)
                             →  Servicio E (Slack)
```

SNS implementa el patrón **Publish/Subscribe**:
- **Publicador**: envía mensajes al topic sin saber quién los recibe
- **Suscriptores**: se suscriben al topic y reciben todos los mensajes relevantes

---

## Recurso 1 — Topic SNS simple

```hcl
resource "aws_sns_topic" "alertas" {
  name = "${local.prefijo}-alertas"
  tags = local.tags
}
```

Un topic es el "canal" al que se publican mensajes. Por sí solo no hace nada; necesita suscriptores.

---

## Recurso 2 — Topic FIFO

```hcl
resource "aws_sns_topic" "pedidos" {
  name                        = "${local.prefijo}-pedidos.fifo"
  fifo_topic                  = true
  content_based_deduplication = true

  tags = merge(local.tags, { tipo = "fifo" })
}
```

Igual que SQS FIFO: garantiza orden y elimina duplicados. El nombre **debe terminar en `.fifo`**.

---

## Colas SQS como destino de las suscripciones

```hcl
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
```

SNS puede enviar mensajes a muchos destinos: SQS, Lambda, HTTP, email... Aquí usamos SQS porque es fácil de verificar en LocalStack.

---

## Patrón Fan-out — Un topic, múltiples suscriptores

```hcl
# Cola email: recibe alertas de tipo "email" o "critico"
resource "aws_sns_topic_subscription" "alertas_to_email" {
  topic_arn = aws_sns_topic.alertas.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.email_queue.arn

  filter_policy = jsonencode({
    tipo_alerta = ["email", "critico"]
  })
}

# Cola SMS: recibe alertas de tipo "sms" o "critico" con prioridad "alta"
resource "aws_sns_topic_subscription" "alertas_to_sms" {
  topic_arn = aws_sns_topic.alertas.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.sms_queue.arn

  filter_policy = jsonencode({
    tipo_alerta = ["sms", "critico"]
    prioridad   = ["alta"]
  })
}

# Cola Slack: recibe TODO (sin filtro)
resource "aws_sns_topic_subscription" "alertas_to_slack" {
  topic_arn = aws_sns_topic.alertas.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.slack_queue.arn
}
```

**El patrón fan-out en acción:**

```
              ┌─────────────────────────────────┐
              │         SNS Topic: alertas       │
              └────────────┬────────────────────┘
                           │ Mensaje publicado:
                           │ {tipo_alerta: "email", prioridad: "alta"}
             ┌─────────────┼──────────────────────┐
             ▼             ▼                       ▼
      email_queue      sms_queue             slack_queue
      ✅ Recibe       ❌ No recibe           ✅ Recibe
      (tipo=email)   (falta prioridad=alta) (sin filtro=todo)
```

**`filter_policy`**: Filtra qué mensajes llegan a cada suscriptor. Si el mensaje tiene los atributos que coinciden con el filtro, la suscripción recibe el mensaje. Si no coincide, lo ignora.

**Importante**: Los filtros se aplican sobre los **message attributes** del mensaje SNS, no sobre el body. Los atributos se envían junto al mensaje al publicar.

---

## Política del topic

```hcl
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
```

La política del topic controla quién puede publicar mensajes en él. En producción restringirías el `"*"` a los servicios específicos que tienen permitido publicar.

---

## Topics y suscripciones dinámicas con `flatten`

Esta es la parte más avanzada del módulo. Hay 3 topics, cada uno con lista de suscriptores. Necesitamos crear una cola por cada par (topic, suscriptor).

```hcl
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
```

La estructura tiene **listas anidadas** dentro del mapa:

```
"errores" → suscriptores = ["equipo-backend", "equipo-ops"]
"despliegues" → suscriptores = ["equipo-devops"]
"seguridad" → suscriptores = ["equipo-seguridad", "equipo-ops"]
```

El problema: `for_each` necesita un mapa plano, no estructuras anidadas.

### `flatten` — La solución para estructuras anidadas

```hcl
locals {
  suscripciones = flatten([
    for topic_key, topic_config in var.topics_config : [
      for suscriptor in topic_config.suscriptores : {
        topic_key  = topic_key
        suscriptor = suscriptor
        key        = "${topic_key}-${suscriptor}"
      }
    ]
  ])

  suscripciones_map = { for s in local.suscripciones : s.key => s }
}
```

**¿Qué hace `flatten`?**

Transforma una lista de listas en una lista plana:

```hcl
flatten([[1, 2], [3], [4, 5]])
# Resultado: [1, 2, 3, 4, 5]
```

**El proceso paso a paso:**

1. El `for` externo itera sobre cada topic
2. El `for` interno itera sobre cada suscriptor del topic
3. Cada iteración genera un objeto con `topic_key`, `suscriptor` y `key`
4. `flatten` aplana el resultado de "lista de listas de objetos" a "lista de objetos"

**Resultado de `local.suscripciones`:**

```hcl
[
  { topic_key = "errores",     suscriptor = "equipo-backend",   key = "errores-equipo-backend"   }
  { topic_key = "errores",     suscriptor = "equipo-ops",       key = "errores-equipo-ops"       }
  { topic_key = "despliegues", suscriptor = "equipo-devops",    key = "despliegues-equipo-devops" }
  { topic_key = "seguridad",   suscriptor = "equipo-seguridad", key = "seguridad-equipo-seguridad" }
  { topic_key = "seguridad",   suscriptor = "equipo-ops",       key = "seguridad-equipo-ops"     }
]
```

**`local.suscripciones_map`** convierte esa lista en un mapa indexado por `key` para poder usarlo con `for_each`.

---

## Crear colas y suscripciones dinámicas

```hcl
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
```

Con 5 pares (topic, suscriptor), Terraform crea automáticamente:
- 5 colas SQS (una por suscriptor por topic)
- 5 suscripciones SNS→SQS

Para agregar un suscriptor nuevo, solo añades una entrada en `var.topics_config`.

---

## Outputs

```hcl
output "total_suscripciones" {
  value = length(local.suscripciones_map) + 3   # dinámicas + 3 fijas
}

output "comando_publicar" {
  value = "aws --endpoint-url=http://localhost:4566 sns publish --topic-arn ${aws_sns_topic.alertas.arn} --message '{\"alerta\": \"test\"}' --message-attributes '{\"tipo_alerta\": {\"DataType\": \"String\", \"StringValue\": \"email\"}}'"
}
```

El output `comando_publicar` genera el comando completo para publicar un mensaje con el atributo `tipo_alerta = "email"`. Según los filtros configurados, solo las colas `email_queue` y `slack_queue` deberían recibir este mensaje.

---

## Comandos para verificar en LocalStack

```bash
# Listar topics
aws --endpoint-url=http://localhost:4566 sns list-topics

# Listar suscripciones de un topic
aws --endpoint-url=http://localhost:4566 sns list-subscriptions-by-topic \
  --topic-arn arn:aws:sns:us-east-1:000000000000:lab-dev-alertas

# Publicar un mensaje con atributos
aws --endpoint-url=http://localhost:4566 sns publish \
  --topic-arn arn:aws:sns:us-east-1:000000000000:lab-dev-alertas \
  --message '{"alerta": "servidor caído"}' \
  --message-attributes '{"tipo_alerta": {"DataType": "String", "StringValue": "email"}}'

# Verificar que llegó a la cola email
aws --endpoint-url=http://localhost:4566 sqs receive-message \
  --queue-url http://localhost:4566/000000000000/lab-dev-sns-emails
```

---

## Ejercicios propuestos

1. Agrega un nuevo topic `"metricas"` al mapa `topics_config` con suscriptores `["equipo-devops", "equipo-backend"]`. Ejecuta `terraform plan` y cuenta cuántos recursos nuevos se crean.

2. Publica un mensaje con `tipo_alerta = "critico"` usando el comando del output. ¿Qué colas reciben el mensaje según los filtros?

3. Modifica el `filter_policy` de `alertas_to_sms` para que también acepte `prioridad = "media"`. ¿Terraform modifica la suscripción o la destruye y recrea?

4. Agrega un filtro a `alertas_to_slack` para que solo reciba mensajes con `entorno = ["produccion"]`.

5. Usa `terraform output suscripciones_creadas` y examina la estructura del mapa retornado.
