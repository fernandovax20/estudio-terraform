# ============================================================
# PASO 1: Crear la infraestructura para el backend remoto
# ============================================================
# Ejecutar PRIMERO: este paso crea el bucket S3 y la tabla
# DynamoDB necesarios para almacenar el state remotamente.
#
#   cd modulo-10-state/paso-1-backend
#   terraform init
#   terraform apply -auto-approve
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
    sts      = "http://localhost:4566"
  }
}

# Bucket S3 para almacenar el state
resource "aws_s3_bucket" "terraform_state" {
  bucket = "lab-terraform-state"

  tags = {
    proposito = "terraform-backend"
    proyecto  = "estudio-terraform"
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Tabla DynamoDB para locking del state
resource "aws_dynamodb_table" "terraform_locks" {
  name         = "lab-terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    proposito = "terraform-state-locking"
    proyecto  = "estudio-terraform"
  }
}

output "backend_bucket" {
  value = aws_s3_bucket.terraform_state.bucket
}

output "backend_dynamodb_table" {
  value = aws_dynamodb_table.terraform_locks.name
}

output "instrucciones" {
  value = <<-EOF
    ¡Backend creado! Ahora puedes:
    1. Ir al directorio padre: cd ..
    2. Descomentar el bloque "backend" en main.tf
    3. Ejecutar: terraform init -migrate-state
  EOF
}
