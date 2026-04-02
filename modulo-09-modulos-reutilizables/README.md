# Módulo 09 — Módulos Reutilizables

## ¿Qué vas a aprender?

- Qué es un módulo de Terraform y por qué usarlos
- Crear módulos propios con variables, recursos y outputs
- Llamar a módulos desde otro archivo con `module {}`
- Pasar variables a módulos y recibir outputs de ellos
- Usar `for_each` en un bloque `module` para crear múltiples instancias
- Conectar módulos entre sí (output de un módulo → input de otro)
- Diferencia entre un "módulo raíz" y un "módulo hijo"

---

## Cómo ejecutar este módulo

```bash
docker-compose up -d
cd modulo-09-modulos-reutilizables
terraform init
terraform apply -auto-approve
terraform state list   # Verás module.xxx.recurso
terraform output
terraform destroy
```

---

## Concepto previo — ¿Por qué módulos?

Sin módulos, si necesitas crear la misma infraestructura para 3 microservicios (cola SQS + DLQ + SNS topic), copiarías y pegarías el código 3 veces. Cuando necesites cambiar algo, lo cambiarías en 3 lugares.

Con módulos, escribes el código una vez y lo reutilizas:

```hcl
module "servicio_pagos" {
  source = "./modulos/microservicio"    # El código está aquí
  nombre = "pagos"
}

module "servicio_envios" {
  source = "./modulos/microservicio"    # Mismo código
  nombre = "envios"
}
```

Los módulos son como **funciones** en programación: encapsulan lógica reutilizable.

---

## Estructura del proyecto

```
modulo-09-modulos-reutilizables/
├── main.tf                        ← Módulo raíz (llama a los módulos hijos)
└── modulos/
    ├── microservicio/
    │   └── main.tf                ← Módulo hijo: define cola + DLQ + SNS topic
    └── bucket-seguro/
        └── main.tf                ← Módulo hijo: define bucket S3 con best practices
```

---

## El módulo hijo: `modulos/microservicio/`

Este módulo encapsula toda la infraestructura de un microservicio:

```hcl
# Variables (interfaz de entrada del módulo)
variable "nombre" {
  type = string
}

variable "entorno" {
  type = string
}

variable "max_reintentos" {
  type    = number
  default = 3
}

variable "retencion_mensajes_horas" {
  type    = number
  default = 24
}

variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  prefijo = "${var.entorno}-${var.nombre}"  # "dev-pagos"
}

# DLQ
resource "aws_sqs_queue" "dlq" {
  name                      = "${local.prefijo}-dlq"
  message_retention_seconds = var.retencion_mensajes_horas * 3600 * 7
}

# Cola principal con redrive hacia la DLQ
resource "aws_sqs_queue" "entrada" {
  name = "${local.prefijo}-entrada"

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_reintentos
  })
}

# Topic SNS para publicar eventos
resource "aws_sns_topic" "eventos" {
  name = "${local.prefijo}-eventos"
}

# Parámetros SSM de configuración
resource "aws_ssm_parameter" "config" {
  name  = "/${local.prefijo}/config"
  type  = "String"
  value = jsonencode({
    max_reintentos = var.max_reintentos
    retencion_horas = var.retencion_mensajes_horas
  })
}

# Outputs (interfaz de salida del módulo)
output "cola_entrada_url"  { value = aws_sqs_queue.entrada.id }
output "cola_entrada_arn"  { value = aws_sqs_queue.entrada.arn }
output "topic_eventos_arn" { value = aws_sns_topic.eventos.arn }
```

**Reglas de un módulo hijo:**

1. Tiene sus propias `variable {}` — son su API de entrada
2. Crea recursos internos
3. Tiene `output {}` — son su API de salida
4. **No tiene un bloque `provider`** (hereda el del módulo raíz)
5. **No tiene el bloque `terraform {}`** (excepto para declarar providers extra)

---

## El módulo raíz: llamar a módulos hijos

```hcl
module "servicio_pagos" {
  source = "./modulos/microservicio"

  nombre                   = "pagos"
  entorno                  = var.entorno
  max_reintentos           = 5
  retencion_mensajes_horas = 72
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
```

Cada `module {}` llama al módulo con sus propios valores. El mismo código de `./modulos/microservicio` crea infraestructura diferente para cada llamada.

**Cómo los recursos aparecen en el state:**

```bash
terraform state list

# module.servicio_pagos.aws_sqs_queue.entrada
# module.servicio_pagos.aws_sqs_queue.dlq
# module.servicio_pagos.aws_sns_topic.eventos
# module.servicio_notificaciones.aws_sqs_queue.entrada
# module.servicio_notificaciones.aws_sqs_queue.dlq
# ...
```

El prefijo `module.nombre_del_modulo.` identifica a qué instancia de módulo pertenece cada recurso.

---

## `for_each` en módulos

```hcl
variable "microservicios" {
  type = map(object({
    max_reintentos = number
    retencion      = number
  }))
  default = {
    "usuarios"  = { max_reintentos = 3,  retencion = 24  }
    "auditoria" = { max_reintentos = 10, retencion = 168 }
    "analytics" = { max_reintentos = 2,  retencion = 12  }
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
```

`for_each` en un módulo funciona igual que en un recurso: crea múltiples instancias del módulo a partir de un mapa.

Para agregar un nuevo microservicio, solo añades una línea al mapa. Para eliminarlo, lo quitas. Terraform se encarga del resto.

**En el state aparecen como:**

```
module.servicios_dinamicos["usuarios"].aws_sqs_queue.entrada
module.servicios_dinamicos["auditoria"].aws_sqs_queue.entrada
module.servicios_dinamicos["analytics"].aws_sqs_queue.entrada
```

---

## El módulo `bucket-seguro`

```hcl
module "bucket_datos" {
  source = "./modulos/bucket-seguro"

  nombre     = "datos-principales"
  entorno    = var.entorno
  versionado = true
  tags       = local.tags_globales
}

module "bucket_temporal" {
  source = "./modulos/bucket-seguro"

  nombre     = "temporal"
  entorno    = var.entorno
  versionado = false   # No versionar archivos temporales
  tags       = local.tags_globales
}
```

El módulo `bucket-seguro` tiene una variable `versionado` booleana. Internamente usa `count` para decidir si crea o no el recurso de versionado:

```hcl
resource "aws_s3_bucket_versioning" "this" {
  count  = var.versionado ? 1 : 0   # Si versionado=true → crea 1, si false → crea 0
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}
```

`count = 0` hace que Terraform no cree el recurso. `count = 1` crea uno.

---

## Conectar módulos entre sí

Los outputs de un módulo se pueden usar como inputs de otro. Así se construyen arquitecturas complejas a partir de piezas más simples.

```hcl
# Suscribir la cola de notificaciones al topic de pagos
resource "aws_sns_topic_subscription" "pagos_a_notificaciones" {
  topic_arn = module.servicio_pagos.topic_eventos_arn        # Output del módulo pagos
  protocol  = "sqs"
  endpoint  = module.servicio_notificaciones.cola_entrada_arn # Output del módulo notificaciones
}
```

**Cómo acceder a los outputs de un módulo:**

```hcl
module.nombre_del_modulo.nombre_del_output

# Ejemplos:
module.servicio_pagos.cola_entrada_url
module.servicio_pagos.topic_eventos_arn
module.bucket_datos.bucket_id
```

---

## Guardar configuración de todos los servicios en S3

```hcl
resource "aws_s3_object" "servicios_config" {
  bucket = module.bucket_datos.bucket_id
  key    = "config/servicios.json"
  content = jsonencode({
    pagos = {
      cola    = module.servicio_pagos.cola_entrada_url
      eventos = module.servicio_pagos.topic_eventos_arn
    }
    notificaciones = {
      cola    = module.servicio_notificaciones.cola_entrada_url
      eventos = module.servicio_notificaciones.topic_eventos_arn
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
```

Este recurso mezcla outputs de módulos estáticos (`servicio_pagos`) y dinámicos (`servicios_dinamicos`). La expresión `for k, m in module.servicios_dinamicos` itera sobre todas las instancias del módulo creadas con `for_each`.

---

## Ventajas de los módulos

| | Sin módulos | Con módulos |
|---|---|---|
| **Duplicación** | Copias del mismo código | Un solo lugar |
| **Consistencia** | Cada copia puede divergir | Todos usan el mismo código |
| **Mantenimiento** | Cambiar en N lugares | Cambiar en 1 lugar |
| **Testing** | Difícil probar partes | Se puede testear el módulo aislado |
| **Onboarding** | Difícil entender el código | La interfaz del módulo es clara |

---

## Ejercicios propuestos

1. Agrega un nuevo servicio `"logs"` al mapa `microservicios` con `max_reintentos = 1` y `retencion = 6`. Ejecuta `terraform plan`.

2. Modifica el módulo `microservicio` para agregar un nuevo output con la URL de la DLQ. Luego úsalo en un output del módulo raíz.

3. En el módulo `bucket-seguro`, agrega un nuevo parámetro `prefix_lifecycle_dias` de tipo `number` con default `30`. Úsalo para configurar una regla de lifecycle que expire objetos con prefijo `"temp/"` después de esos días.

4. Ejecuta `terraform state list` y cuenta cuántos recursos hay en total. ¿Coincide con lo que esperabas?

5. Usa `terraform state show module.servicio_pagos.aws_sqs_queue.entrada` y examina todos los atributos del recurso.
