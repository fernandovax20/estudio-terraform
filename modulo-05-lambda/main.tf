# ============================================================
# MÓDULO 05: LAMBDA FUNCTIONS - Computación serverless
# ============================================================
# Aprenderás:
#   - Crear funciones Lambda
#   - Empaquetar código (archive_file data source)
#   - Permisos Lambda (roles IAM)
#   - Variables de entorno
#   - CloudWatch Logs
#   - Invocar Lambda desde Terraform
#   - Lifecycle (ignore_changes, create_before_destroy)
#
# Comandos:
#   cd modulo-05-lambda
#   terraform init && terraform apply -auto-approve
# ============================================================

terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
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
    iam        = "http://localhost:4566"
    lambda     = "http://localhost:4566"
    sts        = "http://localhost:4566"
    cloudwatch = "http://localhost:4566"
    logs       = "http://localhost:4566"
    s3         = "http://localhost:4566"
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
    modulo   = "05-lambda"
  }
}

# --------------------------------------------------
# ROL IAM PARA LAMBDA
# --------------------------------------------------
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.prefijo}-lambda-execution"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "lambda_permisos" {
  name = "${local.prefijo}-lambda-permisos"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "arn:aws:s3:::${local.prefijo}-*/*"
      }
    ]
  })
}

# --------------------------------------------------
# EMPAQUETAR CÓDIGO (data "archive_file")
# --------------------------------------------------
# archive_file crea un ZIP del código fuente.
# Terraform detecta cambios en el código y re-despliega.

data "archive_file" "lambda_index" {
  type        = "zip"
  source_file = "${path.module}/src/index.py"
  output_path = "${path.module}/dist/index.zip"
}

data "archive_file" "lambda_procesador" {
  type        = "zip"
  source_file = "${path.module}/src/procesador.py"
  output_path = "${path.module}/dist/procesador.zip"
}

# --------------------------------------------------
# FUNCIÓN LAMBDA: Hello World
# --------------------------------------------------
resource "aws_lambda_function" "hello" {
  function_name    = "${local.prefijo}-hello-world"
  filename         = data.archive_file.lambda_index.output_path
  source_code_hash = data.archive_file.lambda_index.output_base64sha256
  handler          = "index.handler"
  runtime          = "python3.11"
  role             = aws_iam_role.lambda.arn
  timeout          = 30
  memory_size      = 128

  # Variables de entorno accesibles desde el código
  environment {
    variables = {
      ENTORNO     = var.entorno
      LOG_LEVEL   = "INFO"
      APP_VERSION = "1.0.0"
    }
  }

  tags = local.tags
}

# --------------------------------------------------
# FUNCIÓN LAMBDA: Procesador de mensajes
# --------------------------------------------------
resource "aws_lambda_function" "procesador" {
  function_name    = "${local.prefijo}-procesador-sqs"
  filename         = data.archive_file.lambda_procesador.output_path
  source_code_hash = data.archive_file.lambda_procesador.output_base64sha256
  handler          = "procesador.handler"
  runtime          = "python3.11"
  role             = aws_iam_role.lambda.arn
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      ENTORNO = var.entorno
    }
  }

  # Lifecycle: controla cómo Terraform gestiona el recurso
  lifecycle {
    # create_before_destroy: crea el nuevo antes de destruir el viejo
    create_before_destroy = true
  }

  tags = local.tags
}

# --------------------------------------------------
# CLOUDWATCH LOG GROUP (para ver logs de Lambda)
# --------------------------------------------------
resource "aws_cloudwatch_log_group" "hello_logs" {
  name              = "/aws/lambda/${aws_lambda_function.hello.function_name}"
  retention_in_days = 7

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "procesador_logs" {
  name              = "/aws/lambda/${aws_lambda_function.procesador.function_name}"
  retention_in_days = 7

  tags = local.tags
}

# --------------------------------------------------
# LAMBDA PERMISSION (permitir invocación externa)
# --------------------------------------------------
resource "aws_lambda_permission" "allow_cloudwatch" {
  statement_id  = "AllowCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.hello.function_name
  principal     = "events.amazonaws.com"
}

# --------------------------------------------------
# OUTPUTS
# --------------------------------------------------
output "lambda_hello_arn" {
  value = aws_lambda_function.hello.arn
}

output "lambda_hello_nombre" {
  value = aws_lambda_function.hello.function_name
}

output "lambda_procesador_arn" {
  value = aws_lambda_function.procesador.arn
}

output "log_groups" {
  value = [
    aws_cloudwatch_log_group.hello_logs.name,
    aws_cloudwatch_log_group.procesador_logs.name,
  ]
}

output "comando_invocar_lambda" {
  description = "Comando para invocar la Lambda en LocalStack"
  value       = "aws --endpoint-url=http://localhost:4566 lambda invoke --function-name ${aws_lambda_function.hello.function_name} --payload '{\"key\": \"value\"}' /dev/stdout"
}

# --------------------------------------------------
# EJERCICIOS PROPUESTOS:
# --------------------------------------------------
# 1. Modifica el código Python en src/index.py y haz terraform apply.
#    ¿Terraform detecta el cambio? (Sí, gracias a source_code_hash)
#
# 2. Agrega una nueva variable de entorno a la función hello.
#
# 3. Cambia el timeout a 120 y la memoria a 512. Observa el plan.
#
# 4. Crea una tercera función Lambda que lea de S3.
#
# 5. Invoca la Lambda con el comando del output:
#    aws --endpoint-url=http://localhost:4566 lambda invoke \
#      --function-name lab-dev-hello-world \
#      --payload '{"nombre": "Fernando"}' /dev/stdout
