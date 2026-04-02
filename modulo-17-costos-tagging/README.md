# Módulo 17 — Costos y Tagging

## ¿Qué vas a aprender?

- Por qué el tagging es la base del control de costos
- `default_tags` en el provider: tagging automático de todos los recursos
- Diseñar una estrategia de tagging corporativa
- Asignar costos por equipo, proyecto y centro de costos
- Configurar alertas de presupuesto con SNS
- Generar reportes de costos en Terraform
- El patrón `map(object)` para estructuras de configuración complejas

---

## Cómo ejecutar este módulo

```bash
docker-compose up -d
cd modulo-17-costos-tagging
terraform init
terraform apply -auto-approve
terraform output
terraform destroy
```

---

## El problema sin tagging

```
Factura de AWS: $50,000 este mes

¿Quién gastó qué?
  - ¿Qué equipo usó más?
  - ¿Qué proyecto está sobrecosteando?
  - ¿Qué recurso se olvidó encendido?

Sin tags: imposible saberlo.
Con tags: se puede ver cada céntimo por equipo y proyecto.
```

El tagging no solo sirve para costos: también para:
- Automatización: "apagar todas las instancias con `Entorno=dev` a las 20:00"
- Seguridad: políticas IAM que solo permiten acceso a recursos con ciertas tags
- Cumplimiento: auditar qué recursos no tienen sus tags obligatorias
- Operaciones: filtrar recursos por equipo o proyecto en la consola de AWS

---

## `default_tags`: tagging automático en el provider

Sin `default_tags`, tendrías que añadir el bloque `tags` a cada recurso:

```hcl
# SIN default_tags: tedioso y propenso a errores
resource "aws_s3_bucket" "ejemplo" {
  bucket = "mi-bucket"
  tags = {
    Proyecto      = "web-app"
    Entorno       = "produccion"
    GestionadoPor = "terraform"
    Equipo        = "backend"
    CentroCoste   = "CC-001"
  }
}

resource "aws_sqs_queue" "ejemplo" {
  name = "mi-cola"
  tags = {                     # Copiado y pegado en cada recurso
    Proyecto      = "web-app"
    Entorno       = "produccion"
    GestionadoPor = "terraform"
    Equipo        = "backend"
    CentroCoste   = "CC-001"
  }
}
```

Con `default_tags`, defines las tags una vez en el provider y se aplican a todos los recursos:

```hcl
provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      GestionadoPor  = "terraform"          # Siempre iguales
      Repositorio    = "github.com/empresa/infra"
      Entorno        = var.entorno
      FechaCreacion  = "2024"
    }
  }
}

# Ahora NO necesitas el bloque `tags` en cada recurso
resource "aws_s3_bucket" "ejemplo" {
  bucket = "mi-bucket"
  # ¡Las tags del default_tags se aplican automáticamente!
}

resource "aws_sqs_queue" "ejemplo" {
  name = "mi-cola"
  # También aquí
}
```

**Combinación de tags:** Si un recurso tiene su propio bloque `tags`, se combinan. Las específicas del recurso sobreescriben las del `default_tags` si hay conflicto.

---

## Diseño de una estrategia de tagging

No todas las organizaciones necesitan las mismas tags. Una buena estrategia de tagging responde a estas preguntas:

```
¿Quién es el dueño del recurso?  → Tag "Equipo" o "Propietario"
¿A qué proyecto pertenece?       → Tag "Proyecto" o "Aplicacion"
¿Para qué entorno?               → Tag "Entorno" (dev/staging/produccion)
¿Quién paga?                     → Tag "CentroCoste"
¿Qué hace?                       → Tag "Proposito" o "Componente"
¿Cuándo se puede apagar?         → Tag "HorarioOperacion"
```

---

## El patrón `map(object)` para equipos

```hcl
variable "equipos" {
  type = map(object({
    nombre_completo = string
    centro_coste    = string
    presupuesto_usd = number
    email_alerta    = string
    tags_adicionales = map(string)
  }))

  default = {
    "backend" = {
      nombre_completo  = "Equipo Backend"
      centro_coste     = "CC-001"
      presupuesto_usd  = 5000
      email_alerta     = "backend-team@empresa.com"
      tags_adicionales = { Tecnologia = "nodejs" }
    }
    "frontend" = {
      nombre_completo  = "Equipo Frontend"
      centro_coste     = "CC-002"
      presupuesto_usd  = 2000
      email_alerta     = "frontend-team@empresa.com"
      tags_adicionales = { Tecnologia = "react" }
    }
    "datos" = {
      nombre_completo  = "Equipo Data"
      centro_coste     = "CC-003"
      presupuesto_usd  = 8000
      email_alerta     = "data-team@empresa.com"
      tags_adicionales = { Tecnologia = "spark" }
    }
    "devops" = {
      nombre_completo  = "Equipo DevOps"
      centro_coste     = "CC-004"
      presupuesto_usd  = 3000
      email_alerta     = "devops-team@empresa.com"
      tags_adicionales = { Tecnologia = "terraform" }
    }
  }
}
```

Este mapa permite iterar sobre los equipos para crear recursos de forma uniforme:

```hcl
locals {
  # Tags por equipo, combinando las globales + las específicas del equipo
  tags_por_equipo = {
    for equipo, config in var.equipos :
    equipo => merge(
      {                                    # Tags base
        Equipo       = config.nombre_completo
        CentroCoste  = config.centro_coste
        GestionadoPor = "terraform"
        Entorno      = var.entorno
      },
      config.tags_adicionales             # Tags específicas del equipo
    )
  }
}
```

---

## Crear recursos por equipo con `for_each`

```hcl
# Cada equipo tiene su propio bucket de datos
resource "aws_s3_bucket" "por_equipo" {
  for_each = var.equipos

  bucket = "datos-${each.key}-${var.entorno}"

  tags = local.tags_por_equipo[each.key]
}

# Cada equipo tiene su propio parámetro SSM con su configuración
resource "aws_ssm_parameter" "config_equipo" {
  for_each = var.equipos

  name  = "/${var.entorno}/equipos/${each.key}/config"
  type  = "String"
  value = jsonencode({
    nombre       = each.value.nombre_completo
    centro_coste = each.value.centro_coste
    presupuesto  = each.value.presupuesto_usd
  })

  tags = local.tags_por_equipo[each.key]
}
```

---

## Alertas de presupuesto con SNS

```hcl
# Topic SNS por equipo para alertas de presupuesto
resource "aws_sns_topic" "alerta_costos" {
  for_each = var.equipos

  name = "alertas-costos-${each.key}"
  tags = local.tags_por_equipo[each.key]
}

resource "aws_sns_topic_subscription" "email_alerta" {
  for_each = var.equipos

  topic_arn = aws_sns_topic.alerta_costos[each.key].arn
  protocol  = "email"
  endpoint  = each.value.email_alerta   # Email del equipo
}
```

Las alertas reales de presupuesto se configuran en AWS Budgets, pero el canal de notificación (SNS topic) se gestiona aquí:

```hcl
# En producción usarías aws_budgets_budget:
resource "aws_budgets_budget" "por_equipo" {
  for_each = var.equipos

  name         = "budget-${each.key}"
  budget_type  = "COST"
  limit_amount = tostring(each.value.presupuesto_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filters = {
    TagKeyValue = ["tag:CentroCoste$${each.value.centro_coste}"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80   # Alertar al 80% del presupuesto
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerta_costos[each.key].arn]
  }
}
```

---

## Reporte de recursos por equipo

```hcl
output "reporte_recursos" {
  value = {
    for equipo in keys(var.equipos) :
    equipo => {
      bucket_datos    = aws_s3_bucket.por_equipo[equipo].id
      topic_alertas   = aws_sns_topic.alerta_costos[equipo].arn
      presupuesto_usd = var.equipos[equipo].presupuesto_usd
      tags_aplicadas  = length(local.tags_por_equipo[equipo])
    }
  }
}
```

---

## Checklist de tagging

Antes de crear un recurso en producción, verifica:

- [ ] ¿Tiene la tag `Equipo` o `Propietario`?
- [ ] ¿Tiene la tag `Proyecto` o `Aplicacion`?
- [ ] ¿Tiene la tag `Entorno`?
- [ ] ¿Tiene la tag `CentroCoste`?
- [ ] ¿Tiene la tag `GestionadoPor = "terraform"`?
- [ ] ¿Si es temporal, tiene la tag `FechaEliminacion`?

En AWS puedes configurar **Tag Policies** (en AWS Organizations) que requieren ciertas tags como obligatorias. Los recursos sin esas tags pueden ser denegados automáticamente.

---

## Ejercicios propuestos

1. Agrega un nuevo equipo `"seguridad"` con presupuesto de $1500 y email `sec-team@empresa.com`. Ejecuta `terraform plan` y verifica que crea sus recursos.

2. Modifica `default_tags` en el provider para agregar la tag `Proyecto = var.nombre_proyecto`. Añade la variable correspondiente.

3. Crea un output que liste todos los `CentroCoste` en uso y el presupuesto total sumado de todos los equipos.

4. ¿Qué pasa si un recurso tiene `tags = { Entorno = "test" }` pero en `default_tags` el `Entorno` es `"produccion"`? ¿Cuál prevalece?

5. Agrega al módulo un recurso `aws_ssm_parameter` que guarde el presupuesto total (suma de todos los equipos) como parámetro para que otras aplicaciones puedan consultarlo.
