# ============================================================
# MÓDULO 16: BACKUP Y DISASTER RECOVERY
# ============================================================
# Aprenderás:
#   - Estrategias de backup: RPO y RTO
#   - S3 Versioning como backup de objetos
#   - S3 Replication (cross-region)
#   - DynamoDB Point-in-Time Recovery
#   - DynamoDB Backups on-demand
#   - Lifecycle policies (mover a almacenamiento barato)
#   - Snapshots de infraestructura
#   - Multi-region / Multi-AZ
#   - Estrategias de DR: Backup/Restore, Pilot Light, Warm Standby, Active-Active
#
# ╔══════════════════════════════════════════════════════════╗
# ║  CONCEPTOS CLAVE                                        ║
# ║                                                          ║
# ║  RPO (Recovery Point Objective):                         ║
# ║    = ¿Cuántos datos puedo PERDER?                        ║
# ║    RPO de 1 hora → estoy OK perdiendo la última hora     ║
# ║                                                          ║
# ║  RTO (Recovery Time Objective):                          ║
# ║    = ¿Cuánto tiempo puedo estar CAÍDO?                   ║
# ║    RTO de 15 min → debo restaurar en menos de 15 min     ║
# ║                                                          ║
# ║  Menor RPO/RTO = más caro. Hay que encontrar balance.    ║
# ╚══════════════════════════════════════════════════════════╝
#
# Comandos:
#   cd modulo-16-backup-dr
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
    s3       = "http://localhost:4566"
    dynamodb = "http://localhost:4566"
    iam      = "http://localhost:4566"
    sts      = "http://localhost:4566"
    ssm      = "http://localhost:4566"
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
    modulo   = "16-backup-dr"
    entorno  = var.entorno
  }
}

# ===========================================================
# 1. S3 VERSIONING: Backup automático de cada cambio
# ===========================================================
# Con versioning, S3 guarda TODAS las versiones de un objeto.
# Si alguien borra o sobreescribe un archivo, puedes recuperarlo.

resource "aws_s3_bucket" "datos_criticos" {
  bucket = "${local.prefijo}-datos-criticos"
  tags   = merge(local.tags, { backup = "versionado" })
}

resource "aws_s3_bucket_versioning" "datos_criticos" {
  bucket = aws_s3_bucket.datos_criticos.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Lifecycle: mover versiones antiguas a almacenamiento barato
# y borrar después de un tiempo
resource "aws_s3_bucket_lifecycle_configuration" "datos_criticos" {
  bucket = aws_s3_bucket.datos_criticos.id

  # Regla 1: Mover versiones antiguas a almacenamiento frío
  rule {
    id     = "mover-versiones-antiguas"
    status = "Enabled"

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"        # Infrequent Access (más barato)
    }

    noncurrent_version_transition {
      noncurrent_days = 90
      storage_class   = "GLACIER"             # Mucho más barato, acceso lento
    }

    noncurrent_version_expiration {
      noncurrent_days = 365                   # Borrar versiones > 1 año
    }
  }

  # Regla 2: Archivos temporales se borran en 7 días
  rule {
    id     = "limpiar-temporales"
    status = "Enabled"

    filter {
      prefix = "tmp/"
    }

    expiration {
      days = 7
    }
  }

  # Regla 3: Abortar uploads incompletos
  rule {
    id     = "abort-multipart"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# Subimos datos de ejemplo para ver el versionado
resource "aws_s3_object" "config_app" {
  bucket  = aws_s3_bucket.datos_criticos.id
  key     = "config/app.json"
  content = jsonencode({
    version = "1.0.0"
    nota    = "Si modificas esto y haces apply, S3 guardará ambas versiones"
  })

  tags = merge(local.tags, { tipo = "configuracion" })
}

# ===========================================================
# 2. S3 REPLICATION: Backup en otra región
# ===========================================================
# Cross-Region Replication copia automáticamente objetos
# a un bucket en otra región. Si us-east-1 se cae, tus datos
# siguen disponibles en us-west-2.

resource "aws_s3_bucket" "replica_dr" {
  bucket = "${local.prefijo}-replica-dr"
  tags   = merge(local.tags, {
    backup   = "replica-cross-region"
    uso      = "disaster-recovery"
  })
}

resource "aws_s3_bucket_versioning" "replica_dr" {
  bucket = aws_s3_bucket.replica_dr.id
  versioning_configuration {
    status = "Enabled"  # Requerido para replication
  }
}

# Rol IAM para que S3 pueda copiar objetos entre buckets
resource "aws_iam_role" "replication" {
  name = "${local.prefijo}-s3-replication-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "s3.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "replication" {
  name = "replication-policy"
  role = aws_iam_role.replication.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetReplicationConfiguration",
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.datos_criticos.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging"
        ]
        Resource = "${aws_s3_bucket.datos_criticos.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags"
        ]
        Resource = "${aws_s3_bucket.replica_dr.arn}/*"
      }
    ]
  })
}

# ===========================================================
# 3. DYNAMODB: Point-in-Time Recovery (PITR)
# ===========================================================
# PITR permite restaurar una tabla a CUALQUIER segundo
# de los últimos 35 días. Si alguien borra datos por error
# a las 3pm, puedes restaurar la tabla a las 2:59pm.

resource "aws_dynamodb_table" "usuarios" {
  name         = "${local.prefijo}-backup-usuarios"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"

  attribute {
    name = "user_id"
    type = "S"
  }

  # ← Esto es CRÍTICO para datos importantes
  point_in_time_recovery {
    enabled = true
  }

  tags = merge(local.tags, {
    backup = "pitr-enabled"
    rpo    = "continuo"
  })
}

# Tabla de pedidos: backup + Time-To-Live para datos expirados
resource "aws_dynamodb_table" "pedidos" {
  name         = "${local.prefijo}-backup-pedidos"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pedido_id"
  range_key    = "fecha"

  attribute {
    name = "pedido_id"
    type = "S"
  }

  attribute {
    name = "fecha"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  # TTL: DynamoDB borra automáticamente items expirados
  # Útil para datos temporales (sesiones, tokens, etc.)
  ttl {
    attribute_name = "expira_en"
    enabled        = true
  }

  tags = merge(local.tags, {
    backup = "pitr-enabled"
    ttl    = "enabled"
  })
}

# Datos de ejemplo
resource "aws_dynamodb_table_item" "usuario_ejemplo" {
  table_name = aws_dynamodb_table.usuarios.name
  hash_key   = "user_id"

  item = jsonencode({
    user_id = { S = "usr-001" }
    nombre  = { S = "Fernando" }
    email   = { S = "fernando@example.com" }
    nota    = { S = "Si borras esto, PITR lo puede recuperar" }
  })
}

# ===========================================================
# 4. TABLA DE BACKUPS MULTI-SERVICIO
# ===========================================================
# En producción real, CADA servicio necesita su estrategia
# de backup. Esta configuración lo centraliza.

locals {
  servicios_backup = {
    "base-datos-principal" = {
      tipo              = "RDS PostgreSQL"
      backup_automatico = true
      retencion_dias    = 30
      multi_az          = true
      replica_lectura   = true
      pitr              = true
      rpo               = "5 minutos"
      rto               = "15 minutos"
      estrategia        = "Warm Standby"
    }
    "base-datos-analytics" = {
      tipo              = "RDS MySQL"
      backup_automatico = true
      retencion_dias    = 7
      multi_az          = false
      replica_lectura   = false
      pitr              = true
      rpo               = "1 hora"
      rto               = "2 horas"
      estrategia        = "Backup & Restore"
    }
    "cache-redis" = {
      tipo              = "ElastiCache Redis"
      backup_automatico = true
      retencion_dias    = 7
      multi_az          = true
      replica_lectura   = true
      pitr              = false
      rpo               = "1 hora"
      rto               = "30 minutos"
      estrategia        = "Pilot Light"
    }
    "almacenamiento-s3" = {
      tipo              = "S3"
      backup_automatico = true
      retencion_dias    = 365
      multi_az          = true                # S3 siempre es multi-AZ
      replica_lectura   = true                # Cross-region replication
      pitr              = false
      rpo               = "minutos (versioning)"
      rto               = "minutos"
      estrategia        = "Active-Active"
    }
    "cola-mensajes" = {
      tipo              = "SQS"
      backup_automatico = false
      retencion_dias    = 0
      multi_az          = true
      replica_lectura   = false
      pitr              = false
      rpo               = "N/A (mensajes son transitorios)"
      rto               = "automático (SQS es managed)"
      estrategia        = "DLQ como backup"
    }
  }
}

# Guardar la configuración de backup como referencia
resource "aws_ssm_parameter" "backup_config" {
  for_each = local.servicios_backup

  name  = "/backup/${each.key}/config"
  type  = "String"
  value = jsonencode(each.value)

  tags = merge(local.tags, {
    servicio = each.key
    rpo      = each.value.rpo
    rto      = each.value.rto
  })
}

# ===========================================================
# 5. BUCKET PARA BACKUPS CENTRALIZADOS
# ===========================================================
# Patrón común: un bucket central donde se acumulan backups
# de múltiples servicios, con lifecycle para mover a Glacier.

resource "aws_s3_bucket" "backups_central" {
  bucket = "${local.prefijo}-backups-central"

  tags = merge(local.tags, {
    uso        = "backups-centralizados"
    criticidad = "maxima"
  })
}

resource "aws_s3_bucket_versioning" "backups_central" {
  bucket = aws_s3_bucket.backups_central.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups_central" {
  bucket = aws_s3_bucket.backups_central.id

  # Backups diarios → Standard 30 días → Glacier 90 días → borrar 1 año
  rule {
    id     = "daily-backups"
    status = "Enabled"

    filter {
      prefix = "daily/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }
  }

  # Backups mensuales → se guardan 3 años en Glacier
  rule {
    id     = "monthly-backups"
    status = "Enabled"

    filter {
      prefix = "monthly/"
    }

    transition {
      days          = 7
      storage_class = "GLACIER"
    }

    expiration {
      days = 1095  # 3 años
    }
  }

  # Backups de compliance → Deep Archive, 7 años
  rule {
    id     = "compliance"
    status = "Enabled"

    filter {
      prefix = "compliance/"
    }

    transition {
      days          = 1
      storage_class = "DEEP_ARCHIVE"
    }

    expiration {
      days = 2555  # 7 años
    }
  }
}

# Estructura de carpetas en el bucket de backups
resource "aws_s3_object" "backup_readme" {
  bucket  = aws_s3_bucket.backups_central.id
  key     = "README.txt"
  content = <<-EOF
    Estructura de backups:
    daily/         → Backups diarios automáticos (retención: 1 año)
    monthly/       → Backups mensuales (retención: 3 años)
    compliance/    → Backups de compliance (retención: 7 años)
    manual/        → Backups manuales antes de cambios grandes
  EOF
}

# ===========================================================
# OUTPUTS
# ===========================================================
output "buckets_backup" {
  value = {
    datos_criticos = {
      bucket     = aws_s3_bucket.datos_criticos.id
      versioning = "enabled"
      lifecycle  = "30d→IA, 90d→Glacier, 365d→delete"
    }
    replica_dr = {
      bucket = aws_s3_bucket.replica_dr.id
      uso    = "Disaster Recovery (otra región)"
    }
    backups_central = {
      bucket  = aws_s3_bucket.backups_central.id
      diario  = "daily/ → 1 año"
      mensual = "monthly/ → 3 años (Glacier)"
      legal   = "compliance/ → 7 años (Deep Archive)"
    }
  }
}

output "tablas_con_pitr" {
  value = {
    usuarios = {
      tabla = aws_dynamodb_table.usuarios.name
      pitr  = "Habilitado"
      nota  = "Restaurable a cualquier segundo de los últimos 35 días"
    }
    pedidos = {
      tabla = aws_dynamodb_table.pedidos.name
      pitr  = "Habilitado"
      ttl   = "Habilitado (borra items expirados automáticamente)"
    }
  }
}

output "diagrama_dr" {
  value = <<-EOF

    ═══════════════════════════════════════════════════════════
             ESTRATEGIAS DE DISASTER RECOVERY
    ═══════════════════════════════════════════════════════════

    Costo $$$$    Active-Active     RPO ≈ 0, RTO ≈ 0
        ▲         ┌───────────┐     Dos regiones activas al
        │         │ Region A  │◄──► 100% simultáneamente.
        │         │ Region B  │     Para sistemas ultra-críticos.
        │         └───────────┘
        │
        │        Warm Standby       RPO ≈ mins, RTO ≈ mins
        │         ┌───────────┐     Región secundaria con infra
        │         │ Region A ●│     escalada al mínimo, lista para
        │         │ Region B ○│     escalar ante un desastre.
        │         └───────────┘
        │
        │        Pilot Light        RPO ≈ mins, RTO ≈ 10-30 min
        │         ┌───────────┐     Solo los servicios core (DB)
        │         │ Region A ●│     replicados. Compute se levanta
        │         │ Region B ·│     ante desastre.
        │         └───────────┘
        │
    Costo $      Backup & Restore   RPO ≈ horas, RTO ≈ horas
        ▼         ┌───────────┐     Solo backups en otra región.
                  │ Region A ●│     Ante desastre, restaurar todo
                  │ Backup  📦│     desde cero.
                  └───────────┘

    ── ¿Cuál elegir? ───────────────────────────────────
    │ Servicio              │ Estrategia recomendada     │
    ├───────────────────────┼────────────────────────────┤
    │ E-commerce (ventas)   │ Warm Standby / Active      │
    │ Blog corporativo      │ Backup & Restore           │
    │ Banca / Salud         │ Active-Active              │
    │ Analytics interno     │ Pilot Light                │
    │ Dev / Staging         │ Backup & Restore           │
    └───────────────────────┴────────────────────────────┘

    ── Lifecycle de S3 (ahorrar en almacenamiento) ─────
    │
    │  S3 Standard  →30d→  S3-IA  →90d→  Glacier  →365d→  🗑️
    │  ($0.023/GB)       ($0.0125/GB)   ($0.004/GB)  Delete
    │
    │  Para compliance: S3 → Deep Archive ($0.00099/GB, 7 años)
    └───────────────────────────────────────────────────

  EOF
}

# --------------------------------------------------
# EJERCICIOS PROPUESTOS:
# --------------------------------------------------
# 1. Modifica el contenido de aws_s3_object.config_app y
#    ejecuta terraform apply. Luego verifica con:
#    aws --endpoint-url=http://localhost:4566 s3api list-object-versions \
#      --bucket lab-dev-datos-criticos --prefix config/
#    ¿Ves las dos versiones?
#
# 2. Agrega un segundo item a la tabla de usuarios y
#    luego bórralo. Con PITR podrías restaurar la tabla
#    a antes del borrado (en AWS real).
#
# 3. Agrega un nuevo servicio al mapa local.servicios_backup.
#    ¿Qué RPO/RTO le asignarías a un servicio de streaming de video?
#
# 4. Investiga "S3 Object Lock" — es como un candado que
#    impide borrar objetos durante un período. Útil para compliance.
#
# 5. Calcula: si tienes 100GB de backups diarios (retención 1 año),
#    ¿cuánto cuesta en S3 Standard vs Glacier vs Deep Archive?
#
# 6. Diseña una estrategia de DR para tu aplicación favorita.
#    ¿Qué servicios necesitan Active-Active y cuáles solo Backup?
