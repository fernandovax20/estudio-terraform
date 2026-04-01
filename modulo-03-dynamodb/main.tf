# ============================================================
# MÓDULO 03: DYNAMODB - Base de datos NoSQL
# ============================================================
# Aprenderás:
#   - Crear tablas DynamoDB
#   - Partition Key y Sort Key
#   - Índices secundarios globales (GSI)
#   - Índices secundarios locales (LSI)
#   - Capacity modes (PAY_PER_REQUEST vs PROVISIONED)
#   - Terraform provisioners (local-exec)
#   - Insertar items con aws_dynamodb_table_item
#
# Comandos a practicar:
#   cd modulo-03-dynamodb
#   terraform init && terraform plan
#   terraform apply -auto-approve
#   terraform state list
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
    dynamodb = "http://localhost:4566"
    sts      = "http://localhost:4566"
  }
}

# --------------------------------------------------
# VARIABLES
# --------------------------------------------------
variable "prefijo" {
  type    = string
  default = "lab"
}

variable "entorno" {
  type    = string
  default = "dev"
}

locals {
  nombre_base = "${var.prefijo}-${var.entorno}"
  tags = {
    proyecto = "estudio-terraform"
    modulo   = "03-dynamodb"
    entorno  = var.entorno
  }
}

# --------------------------------------------------
# TABLA SIMPLE: Usuarios
# --------------------------------------------------
# La tabla más básica: solo una partition key (hash key).
resource "aws_dynamodb_table" "usuarios" {
  name         = "${local.nombre_base}-usuarios"
  billing_mode = "PAY_PER_REQUEST"  # Pago por consulta (sin aprovisionar capacidad)
  hash_key     = "user_id"          # Partition Key (clave primaria)

  # Definición de atributos usados como claves
  attribute {
    name = "user_id"
    type = "S"  # S = String, N = Number, B = Binary
  }

  tags = local.tags
}

# --------------------------------------------------
# TABLA CON SORT KEY: Pedidos
# --------------------------------------------------
# Partition Key + Sort Key = Clave primaria compuesta.
# Permite múltiples items con el mismo hash_key pero diferente range_key.
resource "aws_dynamodb_table" "pedidos" {
  name         = "${local.nombre_base}-pedidos"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"      # ¿De quién es el pedido?
  range_key    = "pedido_id"    # ¿Cuál pedido?

  attribute {
    name = "user_id"
    type = "S"
  }

  attribute {
    name = "pedido_id"
    type = "S"
  }

  # GSI: Índice secundario global
  # Permite consultar por un atributo diferente a la clave primaria.
  attribute {
    name = "estado"
    type = "S"
  }

  attribute {
    name = "fecha_creacion"
    type = "S"
  }

  global_secondary_index {
    name            = "EstadoIndex"
    hash_key        = "estado"
    range_key       = "fecha_creacion"
    projection_type = "ALL"  # Incluir todos los atributos en el índice
  }

  # Otro GSI para buscar por fecha
  global_secondary_index {
    name            = "FechaIndex"
    hash_key        = "fecha_creacion"
    projection_type = "KEYS_ONLY"  # Solo las claves en el índice
  }

  tags = local.tags
}

# --------------------------------------------------
# TABLA CON PROVISIONED CAPACITY: Productos
# --------------------------------------------------
# Modo aprovisionado: defines cuántas lecturas/escrituras por segundo.
resource "aws_dynamodb_table" "productos" {
  name           = "${local.nombre_base}-productos"
  billing_mode   = "PROVISIONED"
  read_capacity  = 5     # Unidades de lectura por segundo
  write_capacity = 5     # Unidades de escritura por segundo
  hash_key       = "producto_id"
  range_key      = "categoria"

  attribute {
    name = "producto_id"
    type = "S"
  }

  attribute {
    name = "categoria"
    type = "S"
  }

  attribute {
    name = "precio"
    type = "N"
  }

  # GSI con capacidad propia
  global_secondary_index {
    name            = "CategoriaIndex"
    hash_key        = "categoria"
    range_key       = "precio"
    projection_type = "INCLUDE"
    non_key_attributes = ["producto_id"]  # Incluir solo ciertos atributos
    read_capacity   = 3
    write_capacity  = 3
  }

  tags = local.tags
}

# --------------------------------------------------
# INSERTAR DATOS EN LA TABLA (aws_dynamodb_table_item)
# --------------------------------------------------
# Puedes insertar items directamente desde Terraform.
# Nota: Esto es útil para datos de configuración, no para datos dinámicos.

resource "aws_dynamodb_table_item" "usuario_1" {
  table_name = aws_dynamodb_table.usuarios.name
  hash_key   = aws_dynamodb_table.usuarios.hash_key

  item = jsonencode({
    user_id = { S = "USR-001" }
    nombre  = { S = "Fernando" }
    email   = { S = "fernando@ejemplo.com" }
    activo  = { BOOL = true }
    edad    = { N = "30" }
    roles   = { L = [{ S = "admin" }, { S = "developer" }] }
  })
}

resource "aws_dynamodb_table_item" "usuario_2" {
  table_name = aws_dynamodb_table.usuarios.name
  hash_key   = aws_dynamodb_table.usuarios.hash_key

  item = jsonencode({
    user_id = { S = "USR-002" }
    nombre  = { S = "María" }
    email   = { S = "maria@ejemplo.com" }
    activo  = { BOOL = true }
    edad    = { N = "25" }
    roles   = { L = [{ S = "viewer" }] }
  })
}

# --------------------------------------------------
# MÚLTIPLES TABLAS CON for_each
# --------------------------------------------------
variable "tablas_config" {
  description = "Configuración de tablas adicionales"
  type = map(object({
    hash_key  = string
    range_key = string
  }))
  default = {
    "sesiones" = {
      hash_key  = "session_id"
      range_key = "timestamp"
    }
    "auditoria" = {
      hash_key  = "evento_id"
      range_key = "fecha"
    }
  }
}

resource "aws_dynamodb_table" "extras" {
  for_each = var.tablas_config

  name         = "${local.nombre_base}-${each.key}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = each.value.hash_key
  range_key    = each.value.range_key

  attribute {
    name = each.value.hash_key
    type = "S"
  }

  attribute {
    name = each.value.range_key
    type = "S"
  }

  tags = merge(local.tags, { tabla = each.key })
}

# --------------------------------------------------
# OUTPUTS
# --------------------------------------------------
output "tabla_usuarios_arn" {
  description = "ARN de la tabla de usuarios"
  value       = aws_dynamodb_table.usuarios.arn
}

output "tabla_usuarios_nombre" {
  value = aws_dynamodb_table.usuarios.name
}

output "tabla_pedidos_indices" {
  description = "Índices GSI de la tabla pedidos"
  value       = [for gsi in aws_dynamodb_table.pedidos.global_secondary_index : gsi.name]
}

output "todas_las_tablas" {
  description = "Nombres de todas las tablas creadas"
  value = concat(
    [aws_dynamodb_table.usuarios.name],
    [aws_dynamodb_table.pedidos.name],
    [aws_dynamodb_table.productos.name],
    [for t in aws_dynamodb_table.extras : t.name]
  )
}

# --------------------------------------------------
# EJERCICIOS PROPUESTOS:
# --------------------------------------------------
# 1. Agrega un tercer usuario con aws_dynamodb_table_item.
#
# 2. Modifica la tabla "productos" para agregar un nuevo GSI
#    que busque por "producto_id" y "nombre".
#
# 3. Agrega una nueva tabla "logs" al mapa "tablas_config".
#
# 4. Cambia la tabla "productos" de PROVISIONED a PAY_PER_REQUEST.
#    ¿Qué pasa con terraform plan?
#
# 5. Usa "terraform state show aws_dynamodb_table.pedidos"
#    para ver todos los atributos del recurso.
#
# 6. Haz "terraform taint aws_dynamodb_table.usuarios"
#    y luego terraform plan - ¿qué pasa?
