# ============================================================
# MÓDULO 04: IAM - Identidad y Gestión de Acceso
# ============================================================
# Aprenderás:
#   - Roles IAM
#   - Políticas IAM (inline y managed)
#   - Policy documents con data "aws_iam_policy_document"
#   - Usuarios y grupos IAM
#   - Assume role (trust relationships)
#   - Adjuntar políticas a roles
#   - Heredoc syntax (<<EOF)
#
# Comandos:
#   cd modulo-04-iam
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
    iam = "http://localhost:4566"
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
    modulo   = "04-iam"
  }
}

# --------------------------------------------------
# ROL IAM PARA LAMBDA
# --------------------------------------------------
# Un rol IAM define "quién" puede asumir permisos.
# El "assume_role_policy" dice quién puede usar este rol.

# Forma 1: Usando data source (RECOMENDADO - más legible)
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "${local.prefijo}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = local.tags
}

# --------------------------------------------------
# POLÍTICA IAM: Permisos para S3
# --------------------------------------------------
# Una política define "qué acciones" están permitidas o denegadas.

data "aws_iam_policy_document" "s3_full_access" {
  # Permitir listar todos los buckets
  statement {
    sid    = "ListarBuckets"
    effect = "Allow"
    actions = [
      "s3:ListAllMyBuckets",
      "s3:GetBucketLocation",
    ]
    resources = ["arn:aws:s3:::*"]
  }

  # Permitir todas las operaciones en buckets del proyecto
  statement {
    sid    = "AccesoCompletoBucketsProyecto"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::${local.prefijo}-*",
      "arn:aws:s3:::${local.prefijo}-*/*",
    ]
  }

  # Denegar eliminación de buckets (override)
  statement {
    sid    = "ProhibirBorrarBuckets"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket",
    ]
    resources = ["arn:aws:s3:::*"]
  }
}

resource "aws_iam_policy" "s3_policy" {
  name        = "${local.prefijo}-s3-policy"
  description = "Política de acceso a S3 para el proyecto"
  policy      = data.aws_iam_policy_document.s3_full_access.json

  tags = local.tags
}

# Adjuntar la política al rol de Lambda
resource "aws_iam_role_policy_attachment" "lambda_s3" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.s3_policy.arn
}

# --------------------------------------------------
# POLÍTICA INLINE (directamente en el rol)
# --------------------------------------------------
# Las políticas inline se crean dentro del rol.
# No son reutilizables, pero útiles para permisos específicos.
resource "aws_iam_role_policy" "lambda_logs" {
  name = "${local.prefijo}-lambda-logs"
  role = aws_iam_role.lambda_role.id

  # Forma 2: Usando jsonencode (alternativa al heredoc)
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CrearLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# --------------------------------------------------
# ROL PARA EC2 (con inline policy usando heredoc)
# --------------------------------------------------
resource "aws_iam_role" "ec2_role" {
  name = "${local.prefijo}-ec2-role"

  # Forma 3: Usando heredoc (forma clásica)
  assume_role_policy = <<-EOF
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": {
            "Service": "ec2.amazonaws.com"
          },
          "Action": "sts:AssumeRole"
        }
      ]
    }
  EOF

  tags = local.tags
}

# --------------------------------------------------
# POLÍTICA DE DYNAMODB CON CONDICIONES
# --------------------------------------------------
data "aws_iam_policy_document" "dynamodb_restricted" {
  statement {
    sid    = "AccesoDynamoDB"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
      "dynamodb:Scan",
    ]
    resources = [
      "arn:aws:dynamodb:us-east-1:*:table/${local.prefijo}-*"
    ]

    # Condiciones: restringir acceso según contexto
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["us-east-1"]
    }
  }
}

resource "aws_iam_policy" "dynamodb_policy" {
  name   = "${local.prefijo}-dynamodb-policy"
  policy = data.aws_iam_policy_document.dynamodb_restricted.json
  tags   = local.tags
}

resource "aws_iam_role_policy_attachment" "ec2_dynamodb" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.dynamodb_policy.arn
}

# --------------------------------------------------
# USUARIO IAM CON ACCESS KEYS
# --------------------------------------------------
resource "aws_iam_user" "desarrollador" {
  name = "${local.prefijo}-desarrollador"
  tags = merge(local.tags, { tipo = "desarrollador" })
}

resource "aws_iam_user_policy_attachment" "dev_s3" {
  user       = aws_iam_user.desarrollador.name
  policy_arn = aws_iam_policy.s3_policy.arn
}

# --------------------------------------------------
# GRUPO IAM
# --------------------------------------------------
resource "aws_iam_group" "devops" {
  name = "${local.prefijo}-equipo-devops"
}

resource "aws_iam_group_membership" "devops_miembros" {
  name  = "devops-membership"
  group = aws_iam_group.devops.name
  users = [aws_iam_user.desarrollador.name]
}

resource "aws_iam_group_policy_attachment" "devops_s3" {
  group      = aws_iam_group.devops.name
  policy_arn = aws_iam_policy.s3_policy.arn
}

# --------------------------------------------------
# MÚLTIPLES USUARIOS CON for_each
# --------------------------------------------------
variable "usuarios" {
  type = map(object({
    grupo = string
  }))
  default = {
    "ana-garcia"   = { grupo = "devops" }
    "luis-martinez" = { grupo = "devops" }
    "carlos-lopez"  = { grupo = "devops" }
  }
}

resource "aws_iam_user" "equipo" {
  for_each = var.usuarios
  name     = "${local.prefijo}-${each.key}"
  tags     = merge(local.tags, { miembro = each.key })
}

# --------------------------------------------------
# OUTPUTS
# --------------------------------------------------
output "lambda_role_arn" {
  value = aws_iam_role.lambda_role.arn
}

output "ec2_role_arn" {
  value = aws_iam_role.ec2_role.arn
}

output "s3_policy_arn" {
  value = aws_iam_policy.s3_policy.arn
}

output "s3_policy_json" {
  description = "JSON de la política de S3 (para revisar)"
  value       = data.aws_iam_policy_document.s3_full_access.json
}

output "usuarios_creados" {
  value = [for u in aws_iam_user.equipo : u.name]
}

# --------------------------------------------------
# EJERCICIOS PROPUESTOS:
# --------------------------------------------------
# 1. Crea una nueva política que permita solo lectura en S3 (s3:GetObject, s3:ListBucket).
#
# 2. Crea un nuevo rol para "apigateway.amazonaws.com" con la política de S3.
#
# 3. Agrega un nuevo usuario al mapa "usuarios" y observa el plan.
#
# 4. Usa "terraform plan -out=plan.tfplan" y luego "terraform show plan.tfplan".
#
# 5. Modifica la política de DynamoDB para permitir también DeleteItem.
#    ¿Qué recursos se recrean vs actualizan?
