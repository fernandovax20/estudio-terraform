# ============================================================
# MÓDULO 17: GESTIÓN DE COSTOS Y TAGGING
# ============================================================
# Aprenderás:
#   - AWS Budgets: alertas cuando gastas de más
#   - Estrategia de tagging: obligar tags en todos los recursos
#   - Tags para asignar costos por equipo/proyecto/entorno
#   - Cálculo de costos: qué cuesta y qué no
#   - Right-sizing: no pagar por recursos sobredimensionados
#   - Reserved Instances vs On-Demand vs Spot
#   - Herramientas: infracost, AWS Cost Explorer, CloudWatch billing
#   - Políticas para prevenir gastos descontrolados
#
# ╔══════════════════════════════════════════════════════════╗
# ║  LA REGLA DE ORO DE COSTOS EN LA NUBE:                  ║
# ║                                                          ║
# ║  "Si no puedes medir quién gasta qué,                   ║
# ║   no puedes optimizar nada."                             ║
# ║                                                          ║
# ║  TAGS = La base de TODA gestión de costos.               ║
# ║  Sin tags, tu factura de AWS es una caja negra.          ║
# ╚══════════════════════════════════════════════════════════╝
#
# Comandos:
#   cd modulo-17-costos-tagging
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

  # ──────────────────────────────────────────────────
  # DEFAULT TAGS: Se aplican automáticamente a TODOS
  # los recursos creados por este provider.
  # Es la forma más eficiente de asegurar tagging.
  # ──────────────────────────────────────────────────
  default_tags {
    tags = {
      ManagedBy   = "terraform"
      Project     = "estudio-terraform"
      Module      = "17-costos-tagging"
      Environment = "dev"
      CostCenter  = "ingenieria"
    }
  }

  endpoints {
    s3       = "http://localhost:4566"
    dynamodb = "http://localhost:4566"
    iam      = "http://localhost:4566"
    sts      = "http://localhost:4566"
    ssm      = "http://localhost:4566"
    sns      = "http://localhost:4566"
    sqs      = "http://localhost:4566"
  }
}

variable "entorno" {
  type    = string
  default = "dev"
}

# ===========================================================
# 1. ESTRATEGIA DE TAGGING
# ===========================================================
# Los tags son la base para:
# - Saber QUIÉN creó qué (Team, Owner)
# - Saber PARA QUÉ es (Project, Application)
# - Saber CUÁNTO cuesta (CostCenter, Environment)
# - Automatizar (auto-stop en dev, compliance, cleanup)

locals {
  prefijo = "lab-${var.entorno}"

  # ── Tags obligatorios para TODA la empresa ──
  # En producción real, se validan con AWS Config Rules
  # o con OPA/Sentinel policies en el pipeline.
  tags_obligatorios = {
    Environment = var.entorno             # dev, staging, prod
    CostCenter  = "ingenieria"            # Centro de costos
    Team        = "platform"              # Equipo responsable
    Project     = "estudio-terraform"     # Proyecto
    ManagedBy   = "terraform"             # Herramienta de gestión
  }

  # ── Tags por equipo (para cost allocation) ──
  equipos = {
    frontend = {
      team        = "frontend"
      cost_center = "producto"
      presupuesto_mensual = 500
    }
    backend = {
      team        = "backend"
      cost_center = "ingenieria"
      presupuesto_mensual = 1500
    }
    data = {
      team        = "data-engineering"
      cost_center = "datos"
      presupuesto_mensual = 3000
    }
    devops = {
      team        = "devops"
      cost_center = "infraestructura"
      presupuesto_mensual = 2000
    }
  }
}

# ===========================================================
# 2. RECURSOS TAGGEADOS POR EQUIPO
# ===========================================================
# Cada equipo tiene su propio bucket con tags que permiten
# rastrear el costo por equipo en AWS Cost Explorer.

resource "aws_s3_bucket" "equipo" {
  for_each = local.equipos

  bucket = "${local.prefijo}-${each.key}-data"

  tags = merge(local.tags_obligatorios, {
    Team        = each.value.team
    CostCenter  = each.value.cost_center
    Presupuesto = "$${each.value.presupuesto_mensual}/mes"
  })
}

# Tabla DynamoDB por equipo
resource "aws_dynamodb_table" "equipo" {
  for_each = local.equipos

  name         = "${local.prefijo}-${each.key}-tabla"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  tags = merge(local.tags_obligatorios, {
    Team       = each.value.team
    CostCenter = each.value.cost_center
  })
}

# ===========================================================
# 3. ALERTAS DE COSTOS (SNS)
# ===========================================================
# En AWS real se usan AWS Budgets. Aquí simulamos la estructura
# de alertas con SNS para entender el patrón.

resource "aws_sns_topic" "alerta_costos" {
  name = "${local.prefijo}-alertas-costos"

  tags = merge(local.tags_obligatorios, {
    uso = "alertas-de-costo"
  })
}

resource "aws_sns_topic" "alerta_por_equipo" {
  for_each = local.equipos

  name = "${local.prefijo}-alerta-costos-${each.key}"

  tags = merge(local.tags_obligatorios, {
    Team       = each.value.team
    tipo       = "alerta-costo-equipo"
  })
}

# Cola donde caen las alertas (para procesamiento)
resource "aws_sqs_queue" "procesar_alertas" {
  name = "${local.prefijo}-procesar-alertas-costos"

  tags = merge(local.tags_obligatorios, {
    uso = "procesar-alertas-costo"
  })
}

resource "aws_sns_topic_subscription" "alerta_a_cola" {
  topic_arn = aws_sns_topic.alerta_costos.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.procesar_alertas.arn
}

# ===========================================================
# 4. CONFIGURACIÓN DE PRESUPUESTOS
# ===========================================================
# Esto es la referencia de cómo se configurarían
# AWS Budgets con Terraform en producción real.

resource "aws_ssm_parameter" "presupuestos" {
  name = "/costos/presupuestos/config"
  type = "String"
  value = jsonencode({
    explicacion = "En AWS real, usarías aws_budgets_budget"
    presupuesto_total = {
      monto_mensual = 7000
      alertas = [
        { porcentaje = 50, mensaje = "Has usado 50% del presupuesto" },
        { porcentaje = 80, mensaje = "ADVERTENCIA: 80% del presupuesto usado" },
        { porcentaje = 100, mensaje = "ALERTA CRITICA: Presupuesto excedido" },
        { porcentaje = 120, mensaje = "EMERGENCIA: 120% del presupuesto" }
      ]
    }
    presupuesto_por_equipo = {
      for team, config in local.equipos : team => {
        monto_mensual = config.presupuesto_mensual
        alerta_80     = config.presupuesto_mensual * 0.8
        alerta_100    = config.presupuesto_mensual
      }
    }
    ejemplo_terraform = <<-HCL
      # Así se crea un Budget real en AWS:
      resource "aws_budgets_budget" "mensual" {
        name         = "presupuesto-mensual"
        budget_type  = "COST"
        limit_amount = "7000"
        limit_unit   = "USD"
        time_unit    = "MONTHLY"

        notification {
          comparison_operator = "GREATER_THAN"
          threshold           = 80
          threshold_type      = "PERCENTAGE"
          notification_type   = "ACTUAL"
          subscriber_sns_topic_arns = [aws_sns_topic.alerta_costos.arn]
        }
      }
    HCL
  })
}

# ===========================================================
# 5. MAPA DE COSTOS POR SERVICIO
# ===========================================================
# Referencia rápida: qué cuesta y qué no en AWS.

resource "aws_ssm_parameter" "mapa_costos" {
  name = "/costos/referencia/mapa-costos"
  type = "String"
  value = jsonencode({
    GRATUITO = {
      "IAM"                = "Usuarios, roles, políticas: GRATIS"
      "VPC (base)"         = "VPC, subnets, security groups: GRATIS"
      "CloudWatch (básico)" = "Métricas básicas, 10 alarmas: GRATIS"
      "SNS (inicio)"       = "1M publicaciones/mes: GRATIS"
      "SQS (inicio)"       = "1M requests/mes: GRATIS"
      "Lambda (inicio)"    = "1M requests/mes: GRATIS"
      "S3 (inicio)"        = "5GB primer año: GRATIS"
    }
    CUIDADO_CUESTA_MUCHO = {
      "NAT Gateway"        = "$0.045/hr + $0.045/GB = ~$32/mes MÍNIMO por AZ"
      "Load Balancer"      = "$0.0225/hr = ~$16/mes mínimo (sin tráfico)"
      "RDS Multi-AZ"       = "2x el precio de single-AZ"
      "ElastiCache"        = "Pago por hora por nodo (como EC2)"
      "EKS Control Plane"  = "$0.10/hr = $73/mes fijo"
      "Transferencia datos" = "$0.09/GB saliente (gratis entrante)"
      "CloudWatch Logs"    = "$0.50/GB ingestión + $0.03/GB almacenamiento"
      "Elastic IP sin usar" = "$0.005/hr = $3.60/mes (¡cobran por NO usarla!)"
    }
    DONDE_AHORRAR = {
      "EC2 Reserved"       = "Hasta 72% de descuento (compromiso 1-3 años)"
      "EC2 Spot"           = "Hasta 90% de descuento (puede interrumpirse)"
      "Savings Plans"      = "Hasta 66% de descuento (flexible entre servicios)"
      "S3 Intelligent"     = "Mueve automáticamente entre tiers según acceso"
      "Lambda"             = "Solo pagas por ejecución real"
      "DynamoDB On-Demand" = "Solo pagas por operación (bueno para carga variable)"
      "Graviton (ARM)"     = "20% más barato que x86 en EC2/RDS/Lambda"
    }
  })
}

# ===========================================================
# 6. RIGHT-SIZING: No pagues de más
# ===========================================================
# Ejemplo de cómo definir instance types por entorno.
# En dev usas t3.small, en prod t3.xlarge — no al revés.

locals {
  sizing_por_entorno = {
    dev = {
      ec2_type     = "t3.small"
      rds_type     = "db.t3.micro"
      cache_type   = "cache.t3.micro"
      asg_min      = 1
      asg_max      = 2
      multi_az     = false
      nota         = "Mínimo viable. Dev no necesita HA ni performance."
      costo_aprox  = "$50-100/mes"
    }
    staging = {
      ec2_type     = "t3.medium"
      rds_type     = "db.t3.small"
      cache_type   = "cache.t3.small"
      asg_min      = 2
      asg_max      = 4
      multi_az     = true
      nota         = "Similar a prod pero más pequeño. Para pruebas de carga."
      costo_aprox  = "$200-400/mes"
    }
    produccion = {
      ec2_type     = "m6i.xlarge"
      rds_type     = "db.r6g.large"
      cache_type   = "cache.r6g.large"
      asg_min      = 3
      asg_max      = 20
      multi_az     = true
      nota         = "Alta disponibilidad. Graviton (ARM) para ahorrar 20%."
      costo_aprox  = "$800-3000/mes (depende de tráfico)"
    }
  }
}

resource "aws_ssm_parameter" "sizing" {
  for_each = local.sizing_por_entorno

  name  = "/costos/sizing/${each.key}"
  type  = "String"
  value = jsonencode(each.value)

  tags = merge(local.tags_obligatorios, {
    entorno = each.key
  })
}

# ===========================================================
# 7. POLÍTICA DE CLEANUP AUTOMÁTICO
# ===========================================================
# En dev/staging, apagar recursos fuera de horario laboral
# ahorra ~65% del costo de compute.

resource "aws_ssm_parameter" "cleanup_policy" {
  name = "/costos/politicas/cleanup"
  type = "String"
  value = jsonencode({
    "REGLA_1_DEV_HORARIO" = {
      descripcion = "Apagar EC2/RDS de dev fuera de horario"
      horario     = "Lun-Vie 8:00-20:00"
      ahorro      = "~65% en compute de dev"
      como        = "AWS Instance Scheduler o Lambda + EventBridge"
      terraform   = "Crear EventBridge rule + Lambda que pare instancias"
    }
    "REGLA_2_TAGS_EXPIRACION" = {
      descripcion = "Todo recurso de dev debe tener tag Expiration"
      ejemplo     = "Expiration = 2025-12-31"
      accion      = "Lambda semanal que destruye recursos expirados"
      ahorro      = "Elimina recursos olvidados"
    }
    "REGLA_3_SIN_TAG_SIN_VIDA" = {
      descripcion = "Recurso sin tags obligatorios se marca para borrar"
      mecanismo   = "AWS Config Rule → SNS → notificar al equipo"
      plazo       = "7 días para agregar tags o se borra"
    }
    "REGLA_4_SPOT_PARA_CI" = {
      descripcion = "Jobs de CI/CD corren en instancias Spot"
      ahorro      = "Hasta 90% vs On-Demand"
      riesgo      = "Pueden interrumpirse (ok para CI, se reintenta)"
    }
    "REGLA_5_HERRAMIENTAS" = {
      infracost = "Estima costos en cada PR antes de aplicar"
      kubecost  = "Costos por namespace/pod en Kubernetes"
      aws_cost_explorer = "Dashboard nativo de AWS"
      vantage   = "Dashboard de costos multi-cloud"
    }
  })
}

# ===========================================================
# OUTPUTS
# ===========================================================
output "buckets_por_equipo" {
  value = { for k, v in aws_s3_bucket.equipo : k => v.id }
}

output "tablas_por_equipo" {
  value = { for k, v in aws_dynamodb_table.equipo : k => v.name }
}

output "presupuestos" {
  value = {
    for team, config in local.equipos : team => {
      presupuesto = "$${config.presupuesto_mensual}/mes"
      alerta_80   = "$${config.presupuesto_mensual * 0.8}"
    }
  }
}

output "sizing_por_entorno" {
  value = { for k, v in local.sizing_por_entorno : k => {
    compute = v.ec2_type
    db      = v.rds_type
    cache   = v.cache_type
    costo   = v.costo_aprox
  }}
}

output "diagrama_costos" {
  value = <<-EOF

    ═══════════════════════════════════════════════════════════
                 GESTIÓN DE COSTOS EN LA NUBE
    ═══════════════════════════════════════════════════════════

    ┌──── TAGS: La base de todo ────────────────────────────┐
    │                                                        │
    │  Cada recurso DEBE tener estos tags:                   │
    │  ┌──────────────┬──────────────────────────────────┐  │
    │  │ Tag          │ Ejemplo                          │  │
    │  ├──────────────┼──────────────────────────────────┤  │
    │  │ Environment  │ dev / staging / prod             │  │
    │  │ Team         │ frontend / backend / data        │  │
    │  │ CostCenter   │ ingenieria / producto / datos    │  │
    │  │ Project      │ api-pagos / web-tienda           │  │
    │  │ ManagedBy    │ terraform / manual / pulumi      │  │
    │  └──────────────┴──────────────────────────────────┘  │
    │                                                        │
    │  Sin tags → no sabes quién gasta → no puedes optimizar │
    └────────────────────────────────────────────────────────┘

    ┌──── Modelos de precios EC2 ───────────────────────────┐
    │                                                        │
    │  On-Demand ████████████████████ 100%  (pago por hora)  │
    │  Reserved  ██████████           50%  (1-3 años)        │
    │  Savings   ████████████          58%  (flexible)       │
    │  Spot      ██                    10%  (interrumpible)  │
    │                                                        │
    │  Estrategia óptima:                                    │
    │   Base estable    → Reserved Instances (70% de carga)  │
    │   Carga variable  → On-Demand / Auto Scaling           │
    │   Batch / CI/CD   → Spot Instances                     │
    │   Experimentación → Dev apagado fuera de horario       │
    └────────────────────────────────────────────────────────┘

    ┌──── Pipeline de costos ───────────────────────────────┐
    │                                                        │
    │  PR abierto                                            │
    │    │                                                   │
    │    ├── terraform plan                                  │
    │    ├── infracost  →  "Este cambio cuesta +$150/mes"    │
    │    ├── tfsec      →  "S3 sin encriptación"             │
    │    │                                                   │
    │    └── Reviewer: "¿Realmente necesitamos m5.2xlarge    │
    │                   o alcanza con t3.large?"              │
    │                                                        │
    │  Merge                                                 │
    │    │                                                   │
    │    └── AWS Budget → alerta al 80%                      │
    │         └── SNS → Slack: "Llevas $5,600 de $7,000"     │
    └────────────────────────────────────────────────────────┘

    ┌──── TRAMPAS COMUNES (que queman dinero) ──────────────┐
    │                                                        │
    │  ❌ NAT Gateway en dev (gasta $32+/mes por AZ)        │
    │     → Usa VPC Endpoints para S3/DynamoDB               │
    │                                                        │
    │  ❌ Elastic IPs sin usar ($3.60/mes cada una)          │
    │     → Libéralas si no están asociadas a algo           │
    │                                                        │
    │  ❌ EBS volumes huérfanos (quedan al borrar EC2)       │
    │     → Script de limpieza semanal                       │
    │                                                        │
    │  ❌ RDS Multi-AZ en dev (2x el precio)                 │
    │     → Solo Multi-AZ en producción                      │
    │                                                        │
    │  ❌ CloudWatch Logs sin retención                      │
    │     → Poner retention_in_days = 14 en dev              │
    │                                                        │
    │  ❌ Snapshots antiguos (se acumulan silenciosamente)   │
    │     → Lifecycle policies automáticas                   │
    └────────────────────────────────────────────────────────┘

  EOF
}

# --------------------------------------------------
# EJERCICIOS PROPUESTOS:
# --------------------------------------------------
# 1. Agrega un equipo "qa" a local.equipos con presupuesto
#    de $800/mes. ¿Se crean automáticamente bucket + tabla + alerta?
#
# 2. Cambia el entorno a "staging" con:
#    terraform apply -var="entorno=staging"
#    ¿Cambian los tags? ¿Cambiaría el sizing en producción real?
#
# 3. Investiga "infracost" (infracost.io). Instálalo y ejecuta:
#    infracost breakdown --path .
#    sobre cualquier módulo. ¿Cuánto costaría en AWS real?
#
# 4. Crea un recurso SIN los tags obligatorios (quita default_tags).
#    ¿Cómo detectarías esto automáticamente? (pista: AWS Config)
#
# 5. Calcula: tu empresa usa 10 instancias m5.xlarge 24/7.
#    On-Demand = $0.192/hr × 10 × 730hrs = $1,401/mes
#    Reserved (1yr) = ~$840/mes  → Ahorro: $561/mes
#    ¿Cuánto ahorras al año?
#
# 6. Diseña la estrategia de sizing para una startup que
#    empieza con 100 usuarios y espera crecer a 10,000 en 1 año.
