# ============================================================
# MÓDULO REUTILIZABLE: Bucket S3 con mejores prácticas
# ============================================================
# Crea un bucket S3 con:
#   - Versionado opcional
#   - Cifrado (simulado)
#   - Tags estándar

variable "nombre" {
  description = "Nombre del bucket"
  type        = string
}

variable "entorno" {
  description = "Entorno"
  type        = string
}

variable "versionado" {
  description = "Habilitar versionado"
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  nombre_bucket = "${var.entorno}-${var.nombre}"
  tags = merge(var.tags, {
    bucket = var.nombre
    modulo = "bucket-seguro"
  })
}

resource "aws_s3_bucket" "this" {
  bucket = local.nombre_bucket
  tags   = local.tags
}

resource "aws_s3_bucket_versioning" "this" {
  count  = var.versionado ? 1 : 0
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

# --------------------------------------------------
# OUTPUTS
# --------------------------------------------------
output "bucket_id" {
  value = aws_s3_bucket.this.id
}

output "bucket_arn" {
  value = aws_s3_bucket.this.arn
}

output "bucket_nombre" {
  value = aws_s3_bucket.this.bucket
}
