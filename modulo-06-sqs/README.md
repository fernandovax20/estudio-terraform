# Módulo 06 — SQS · Colas de mensajes

## ¿Qué vas a aprender?

- Qué es una cola de mensajes y para qué sirve
- Crear colas SQS estándar y FIFO
- Qué es una Dead Letter Queue (DLQ) y cuándo usarla
- Configurar la `redrive_policy` para reintentos automáticos
- Crear políticas de acceso IAM para colas
- Crear múltiples colas con configuración dinámica usando `for_each`
- Usar condicionales inline en recursos (`... ? valor : null`)

---

## Cómo ejecutar este módulo

```bash
docker-compose up -d
cd modulo-06-sqs
terraform init
terraform apply -auto-approve
terraform output
terraform destroy
```

---

## Concepto previo — ¿Qué es una cola de mensajes?

Una cola de mensajes desacopla dos sistemas: el **productor** (quien envía mensajes) y el **consumidor** (quien los procesa).

**Sin cola:**

```
Servicio A  →  llama directo a  →  Servicio B
              (si B falla, A falla también)
```

**Con cola:**

```
Servicio A  →  envía a  →  Cola SQS  →  Servicio B lo procesa cuando puede
              (si B falla, el mensaje sigue en la cola hasta que B se recupere)
```

Beneficios:
- **Desacoplamiento**: A no necesita saber si B está disponible
- **Resiliencia**: los mensajes no se pierden si B falla
- **Buffer**: si A envía 10.000 mensajes, B los procesa a su ritmo

---

## Recurso 1 — Cola estándar simple

```hcl
resource "aws_sqs_queue" "principal" {
  name                       = "${local.prefijo}-cola-principal"
  delay_seconds              = 0
  max_message_size           = 262144
  message_retention_seconds  = 86400
  visibility_timeout_seconds = 30
  receive_wait_time_seconds  = 10

  tags = local.tags
}
```

**Parámetros explicados:**

| Parámetro | Valor | Significado |
|-----------|-------|-------------|
| `delay_seconds` | `0` | Segundos antes de que el mensaje sea visible. `0` = disponible inmediatamente |
| `max_message_size` | `262144` | Tamaño máximo del mensaje (256 KB) |
| `message_retention_seconds` | `86400` | Cuánto tiempo guardar el mensaje si nadie lo consume. `86400` = 1 día |
| `visibility_timeout_seconds` | `30` | Cuando alguien recibe el mensaje, queda "invisible" por 30s para otros. Si no lo procesa en 30s, vuelve a la cola |
| `receive_wait_time_seconds` | `10` | Long polling: espera hasta 10s por mensajes antes de responder vacío |

**Sobre el `visibility_timeout`:**

```
Consumidor recibe mensaje
     ↓
Mensaje se oculta (30 segundos)
     ↓
¿Procesó el mensaje?
   Sí → elimina el mensaje de la cola ✅
   No (crash o timeout) → mensaje vuelve a la cola para que otro lo procese ♻️
```

---

## Recurso 2 — Dead Letter Queue (DLQ)

```hcl
resource "aws_sqs_queue" "dlq" {
  name                      = "${local.prefijo}-cola-dlq"
  message_retention_seconds = 604800   # 7 días

  tags = merge(local.tags, { tipo = "dead-letter-queue" })
}
```

**¿Qué es una DLQ?**

Una "cola de mensajes muertos". Recibe los mensajes que fallaron después de N intentos. Es un patrón de ingeniería fundamental.

```
Cola principal
     ↓
Consumidor intenta procesar el mensaje
     ↓
¿Procesó bien?  →  Sí: elimina el mensaje ✅
               ↓
              No: reintento
               ↓
¿Superó 3 intentos? → Sí: mueve a la DLQ ⚠️

DLQ:
  - Guarda los mensajes fallidos 7 días
  - El equipo puede investigar qué salió mal
  - Puede reprocesarse cuando se resuelva el bug
```

Ventajas de tener una DLQ:
- Los mensajes fallidos no bloquean la cola principal
- Tienes visibilidad de cuántos mensajes fallan y por qué
- Puedes reenviar los mensajes a la cola principal una vez que se corrija el error

---

## Recurso 3 — Cola con redrive policy (conectada a la DLQ)

```hcl
resource "aws_sqs_queue" "procesamiento" {
  name                       = "${local.prefijo}-cola-procesamiento"
  visibility_timeout_seconds = 60

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })

  tags = local.tags
}
```

**`redrive_policy`:**

- `deadLetterTargetArn` → ARN de la DLQ donde van los mensajes fallidos
- `maxReceiveCount = 3` → Después de 3 intentos fallidos, el mensaje se mueve a la DLQ

Tradución: "Si un mensaje falla 3 veces (el consumidor no lo elimina en el tiempo de visibilidad), enviarlo a la cola DLQ".

---

## Recurso 4 — Cola FIFO

```hcl
resource "aws_sqs_queue" "fifo" {
  name                        = "${local.prefijo}-cola-ordenada.fifo"
  fifo_queue                  = true
  content_based_deduplication = true

  tags = merge(local.tags, { tipo = "fifo" })
}
```

**¿Qué diferencia a FIFO de una cola estándar?**

| | Cola Estándar | Cola FIFO |
|---|---|---|
| **Orden** | Aproximado (best-effort) | Garantizado (primero en entrar = primero en salir) |
| **Deduplicación** | No (puede recibir duplicados) | Sí (no duplica mensajes) |
| **Throughput** | Alto (casi ilimitado) | Limitado (3000 msg/s) |
| **Nombre** | `nombre-cualquiera` | **Debe terminar en `.fifo`** |
| **Cuándo usar** | Procesamiento paralelo, alta carga | Transacciones financieras, pedidos |

**`content_based_deduplication = true`**: SQS calcula un hash del contenido del mensaje. Si llegan dos mensajes idénticos en un período de 5 minutos, el segundo se descarta automáticamente.

---

## Política de acceso a la cola

```hcl
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
```

La política de cola controla **quién puede enviar y recibir mensajes**. El `"*"` en `identifiers` permite acceso a cualquier identidad AWS (útil para laboratorio, no para producción).

---

## Múltiples colas con configuración dinámica

```hcl
variable "colas_config" {
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
      usar_dlq          = false     # analytics no necesita DLQ
    }
  }
}

resource "aws_sqs_queue" "adicionales" {
  for_each = var.colas_config

  name                       = "${local.prefijo}-cola-${each.key}"
  delay_seconds              = each.value.delay_seconds
  message_retention_seconds  = each.value.retention_seconds
  visibility_timeout_seconds = each.value.visibility

  # Condicional inline: si usar_dlq=true, configura el redrive_policy; si no, null
  redrive_policy = each.value.usar_dlq ? jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  }) : null

  tags = merge(local.tags, { cola = each.key })
}
```

**El condicional en un argumento de recurso:**

```hcl
redrive_policy = each.value.usar_dlq ? jsonencode({...}) : null
```

Si `usar_dlq = true` → configura el redrive.  
Si `usar_dlq = false` → `null` (no configura el redrive, como si no existiera el atributo).

Esto permite tener un solo bloque `resource` que se comporta diferente según la configuración de cada cola.

---

## Outputs

```hcl
output "total_colas" {
  value = 4 + length(var.colas_config)   # 4 fijas + dinámicas
}

output "colas_adicionales" {
  value = { for k, q in aws_sqs_queue.adicionales : k => {
    url = q.id
    arn = q.arn
  }}
}

output "comando_enviar_mensaje" {
  value = "aws --endpoint-url=http://localhost:4566 sqs send-message --queue-url ${aws_sqs_queue.principal.id} --message-body '{\"test\": true}'"
}
```

El output `colas_adicionales` devuelve un mapa de objetos (cada objeto tiene `url` y `arn`). Demuestra cómo crear estructuras de salida complejas.

---

## Comandos para verificar en LocalStack

```bash
# Listar todas las colas
aws --endpoint-url=http://localhost:4566 sqs list-queues

# Enviar un mensaje
aws --endpoint-url=http://localhost:4566 sqs send-message \
  --queue-url http://localhost:4566/000000000000/lab-dev-cola-principal \
  --message-body '{"evento": "test", "valor": 42}'

# Recibir el mensaje
aws --endpoint-url=http://localhost:4566 sqs receive-message \
  --queue-url http://localhost:4566/000000000000/lab-dev-cola-principal

# Ver atributos de la cola (retención, DLQ, etc.)
aws --endpoint-url=http://localhost:4566 sqs get-queue-attributes \
  --queue-url http://localhost:4566/000000000000/lab-dev-cola-procesamiento \
  --attribute-names All
```

---

## Ejercicios propuestos

1. Agrega una nueva cola `"pagos"` al mapa `colas_config` con `delay_seconds = 0`, `usar_dlq = true` y retención de 48 horas. Ejecuta `terraform plan`.

2. Envía un mensaje a la cola principal con el comando del output. Luego recíbelo. ¿Ves el `ReceiptHandle`? Lo necesitas para eliminarlo.

3. Cambia el `maxReceiveCount` de la `redrive_policy` de la cola `procesamiento` a `5`. ¿Terraform modifica la cola o la destruye y recrea?

4. Crea una segunda cola FIFO para procesar pagos. El nombre debe terminar en `.fifo`.

5. Usa `terraform state show aws_sqs_queue.procesamiento` y examina el campo `redrive_policy` en el state.
