# ============================================================
# MÓDULO 02: S3 BUCKETS - Almacenamiento de objetos
# ============================================================
# Aprenderás:
#   - Crear buckets S3
#   - Políticas de bucket
#   - Versionado
#   - Configuración de website estático
#   - Subir objetos a S3
#   - Data sources
#   - depends_on (dependencias explícitas)
#
# Comandos a practicar:
#   cd modulo-02-s3
#   terraform init
#   terraform plan
#   terraform apply -auto-approve
#   terraform state list
#   terraform state show aws_s3_bucket.principal
#   terraform destroy
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
    s3  = "http://localhost:4566"
    sts = "http://localhost:4566"
  }
}

# --------------------------------------------------
# VARIABLES
# --------------------------------------------------
variable "nombre_proyecto" {
  description = "Nombre base para los buckets"
  type        = string
  default     = "lab-terraform"
}

variable "entorno" {
  type    = string
  default = "dev"
}

# --------------------------------------------------
# LOCALS
# --------------------------------------------------
locals {
  prefijo = "${var.nombre_proyecto}-${var.entorno}"
  tags = {
    proyecto = var.nombre_proyecto
    entorno  = var.entorno
    modulo   = "02-s3"
  }
}

# --------------------------------------------------
# BUCKET PRINCIPAL
# --------------------------------------------------
# Este es el recurso más básico de S3: un bucket vacío.
resource "aws_s3_bucket" "principal" {
  bucket = "${local.prefijo}-datos-principales"
  tags   = local.tags
}

# --------------------------------------------------
# VERSIONADO DEL BUCKET
# --------------------------------------------------
# El versionado mantiene un historial de cada objeto.
# En Terraform, se configura como recurso separado.
resource "aws_s3_bucket_versioning" "principal" {
  bucket = aws_s3_bucket.principal.id

  versioning_configuration {
    status = "Enabled"
  }
}

# --------------------------------------------------
# BUCKET PARA WEBSITE ESTÁTICO
# --------------------------------------------------
resource "aws_s3_bucket" "website" {
  bucket = "${local.prefijo}-website"
  tags   = merge(local.tags, { uso = "website" })
}

resource "aws_s3_bucket_website_configuration" "website" {
  bucket = aws_s3_bucket.website.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

# --------------------------------------------------
# SUBIR OBJETOS A S3 (aws_s3_object)
# --------------------------------------------------
# Podemos subir archivos directamente con Terraform.

resource "aws_s3_object" "index_html" {
  bucket       = aws_s3_bucket.website.id
  key          = "index.html"
  content      = <<-HTML
    <!DOCTYPE html>
    <html>
    <head><title>Lab Terraform</title></head>
    <body>
      <h1>¡Hola desde Terraform + LocalStack!</h1>
      <p>Este sitio fue desplegado con Terraform.</p>
      <p>Entorno: ${var.entorno}</p>
    </body>
    </html>
  HTML
  content_type = "text/html"

  tags = local.tags
}

resource "aws_s3_object" "error_html" {
  bucket       = aws_s3_bucket.website.id
  key          = "error.html"
  content      = <<-HTML
    <!DOCTYPE html>
    <html>
    <head><title>Error</title></head>
    <body>
      <h1>404 - Página no encontrada</h1>
      <a href="/">Volver al inicio</a>
    </body>
    </html>
  HTML
  content_type = "text/html"

  tags = local.tags
}

# --------------------------------------------------
# BUCKET PARA LOGS (con lifecycle)
# --------------------------------------------------
resource "aws_s3_bucket" "logs" {
  bucket = "${local.prefijo}-logs"
  tags   = merge(local.tags, { uso = "logs" })
}

# --------------------------------------------------
# MÚLTIPLES BUCKETS CON for_each
# --------------------------------------------------
variable "buckets_adicionales" {
  description = "Map de buckets adicionales a crear"
  type        = map(string)
  default = {
    "imagenes"  = "Almacén de imágenes"
    "backups"   = "Copias de seguridad"
    "temporal"  = "Archivos temporales"
  }
}

resource "aws_s3_bucket" "adicionales" {
  for_each = var.buckets_adicionales

  bucket = "${local.prefijo}-${each.key}"
  tags   = merge(local.tags, {
    descripcion = each.value
    nombre      = each.key
  })
}

# --------------------------------------------------
# SUBIR ARCHIVO DE CONFIGURACIÓN JSON
# --------------------------------------------------
resource "aws_s3_object" "config_json" {
  bucket = aws_s3_bucket.principal.id
  key    = "config/settings.json"
  content = jsonencode({
    proyecto    = var.nombre_proyecto
    entorno     = var.entorno
    version     = "1.0.0"
    buckets     = [for k, b in aws_s3_bucket.adicionales : b.bucket]
    timestamp   = timestamp()
  })
  content_type = "application/json"

  # depends_on: Dependencia explícita
  # Terraform normalmente detecta dependencias, pero a veces
  # necesitas declararlas manualmente.
  depends_on = [aws_s3_bucket_versioning.principal]
}

# --------------------------------------------------
# DATA SOURCE: Leer información de un recurso existente
# --------------------------------------------------
# Los data sources permiten consultar información de recursos
# que ya existen (incluso los que acabamos de crear).
data "aws_s3_bucket" "consulta_principal" {
  bucket = aws_s3_bucket.principal.id

  depends_on = [aws_s3_bucket.principal]
}

# --------------------------------------------------
# OUTPUTS
# --------------------------------------------------
output "bucket_principal_arn" {
  description = "ARN del bucket principal"
  value       = aws_s3_bucket.principal.arn
}

output "bucket_principal_id" {
  description = "ID del bucket principal"
  value       = aws_s3_bucket.principal.id
}

output "website_url" {
  description = "URL del website estático"
  value       = aws_s3_bucket_website_configuration.website.website_endpoint
}

output "buckets_adicionales" {
  description = "Mapa de buckets adicionales creados"
  value       = { for k, b in aws_s3_bucket.adicionales : k => b.arn }
}

output "todos_los_buckets" {
  description = "Lista de todos los nombres de bucket"
  value = concat(
    [aws_s3_bucket.principal.bucket],
    [aws_s3_bucket.website.bucket],
    [aws_s3_bucket.logs.bucket],
    [for b in aws_s3_bucket.adicionales : b.bucket]
  )
}

# --------------------------------------------------
# EJERCICIOS PROPUESTOS:
# --------------------------------------------------
# 1. Agrega un nuevo bucket llamado "archivos" al mapa buckets_adicionales.
#    Ejecuta terraform plan - ¿cuántos recursos se crean/destruyen?
#
# 2. Modifica el index.html para agregar más contenido.
#    Ejecuta terraform plan - ¿qué recurso cambia?
#
# 3. Usa "terraform state show aws_s3_bucket.principal" para ver el detalle.
#
# 4. Elimina solo el bucket de logs con:
#    terraform destroy -target=aws_s3_bucket.logs
#
# 5. Crea un output que cuente el total de buckets creados.
#
# 6. Usa "terraform import" para importar un bucket existente
#    (crea uno manualmente con awslocal primero).
