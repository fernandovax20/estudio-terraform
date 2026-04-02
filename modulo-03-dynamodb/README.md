# Módulo 03 — DynamoDB · Base de datos NoSQL

## ¿Qué vas a aprender?

- Crear tablas DynamoDB con `Partition Key` y `Sort Key`
- Diferencia entre `PAY_PER_REQUEST` y `PROVISIONED`
- Índices secundarios globales (GSI) para consultas flexibles
- Insertar datos directamente desde Terraform con `aws_dynamodb_table_item`
- Crear múltiples tablas dinámicamente con `for_each` usando `object` types
- Trabajar con tipos complejos de variable: `map(object({...}))`

---

## Cómo ejecutar este módulo

```bash
docker-compose up -d
cd modulo-03-dynamodb
terraform init
terraform apply -auto-approve
terraform state list
terraform destroy
```

---

## Concepto previo — ¿Qué es DynamoDB?

DynamoDB es la base de datos NoSQL de AWS. A diferencia de una base de datos relacional (SQL), no tiene tablas con columnas fijas. Cada ítem puede tener atributos distintos. Lo único obligatorio es la **clave primaria**.

```
Tabla: usuarios
┌──────────┬──────────┬───────────────────────┬───────┐
│ user_id  │  nombre  │         email         │ edad  │
│ (String) │ (String) │       (String)        │ (Num) │
├──────────┼──────────┼───────────────────────┼───────┤
│ USR-001  │ Fernando │ fernando@ejemplo.com   │  30   │
│ USR-002  │ María    │ maria@ejemplo.com      │  25   │
└──────────┴──────────┴───────────────────────┴───────┘
```

---

## Clave primaria en DynamoDB

DynamoDB tiene dos tipos de clave primaria:

**Tipo 1 — Solo Partition Key (hash key)**

```
user_id = "USR-001"  →  un único ítem
```

Solo puede existir un ítem por valor de `user_id`.

**Tipo 2 — Partition Key + Sort Key (hash key + range key)**

```
user_id = "USR-001" + pedido_id = "PED-2024-01"  →  un único ítem
user_id = "USR-001" + pedido_id = "PED-2024-02"  →  otro ítem
```

El mismo `user_id` puede tener múltiples ítems si tienen diferentes `pedido_id`. Esto modela relaciones uno-a-muchos.

---

## Recurso 1 — Tabla simple con solo Partition Key

```hcl
resource "aws_dynamodb_table" "usuarios" {
  name         = "${local.nombre_base}-usuarios"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"

  attribute {
    name = "user_id"
    type = "S"
  }

  tags = local.tags
}
```

**Parámetros clave:**

| Parámetro | Valor | Significado |
|-----------|-------|-------------|
| `billing_mode` | `PAY_PER_REQUEST` | Paga solo por las consultas que haces. No defines capacidad de antemano |
| `hash_key` | `"user_id"` | La Partition Key. Distribuye los datos internamente |
| `attribute` | `type = "S"` | Solo declaras atributos usados como claves. `S` = String, `N` = Number, `B` = Binary |

**Importante**: En DynamoDB no declaras todos los atributos de la tabla en Terraform, solo los que se usan como claves primarias o en índices. Los demás atributos los defines directamente al insertar datos.

---

## Recurso 2 — Tabla con Partition Key + Sort Key + GSI

```hcl
resource "aws_dynamodb_table" "pedidos" {
  name         = "${local.nombre_base}-pedidos"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"
  range_key    = "pedido_id"

  attribute {
    name = "user_id"
    type = "S"
  }

  attribute {
    name = "pedido_id"
    type = "S"
  }

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
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "FechaIndex"
    hash_key        = "fecha_creacion"
    projection_type = "KEYS_ONLY"
  }

  tags = local.tags
}
```

### ¿Qué es un GSI (Global Secondary Index)?

La clave primaria define cómo consultas la tabla de forma eficiente. Si quieres consultar por otro atributo, necesitas un GSI.

**Problema sin GSI:**
```
# Quiero todos los pedidos en estado "pendiente"
# → DynamoDB tiene que escanear TODA la tabla (muy lento y caro)
```

**Solución con GSI:**
```
# GSI "EstadoIndex" indexa la tabla por "estado"
# → DynamoDB va directo a los pedidos "pendientes" (rápido y barato)
```

### `projection_type` — ¿Qué atributos incluye el índice?

| Valor | Qué incluye | Cuándo usar |
|-------|-------------|-------------|
| `ALL` | Todos los atributos | Cuando necesitas todos los campos en la consulta |
| `KEYS_ONLY` | Solo las claves | Cuando solo necesitas saber si existe el ítem |
| `INCLUDE` | Solo los especificados en `non_key_attributes` | Para optimizar almacenamiento |

---

## Recurso 3 — Tabla con capacidad aprovisionada (PROVISIONED)

```hcl
resource "aws_dynamodb_table" "productos" {
  name           = "${local.nombre_base}-productos"
  billing_mode   = "PROVISIONED"
  read_capacity  = 5
  write_capacity = 5
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

  global_secondary_index {
    name               = "CategoriaIndex"
    hash_key           = "categoria"
    range_key          = "precio"
    projection_type    = "INCLUDE"
    non_key_attributes = ["producto_id"]
    read_capacity      = 3
    write_capacity     = 3
  }

  tags = local.tags
}
```

### `PAY_PER_REQUEST` vs `PROVISIONED`

| | `PAY_PER_REQUEST` | `PROVISIONED` |
|---|---|---|
| **Costo** | Paga por consulta | Paga por capacidad reservada |
| **Cuándo usar** | Tráfico impredecible, bajo o variable | Tráfico estable y predecible |
| **Complejidad** | Ninguna | Requiere calcular capacidad necesaria |
| **Escalamiento** | Automático | Manual o con Auto Scaling |
| **Ideal para** | Desarrollo, startups | Producción con carga conocida |

Con `PROVISIONED`, `read_capacity = 5` significa 5 "Read Capacity Units" por segundo. 1 RCU = leer un ítem de hasta 4KB.

---

## Insertar datos directamente desde Terraform

```hcl
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
```

**Punto importante**: Los ítems en DynamoDB tienen una sintaxis especial para los tipos. Cada valor es un objeto con el tipo como clave:

| Tipo | Sintaxis de DynamoDB | Ejemplo |
|------|---------------------|---------|
| String | `{ S = "valor" }` | `{ S = "Fernando" }` |
| Number | `{ N = "42" }` | `{ N = "30" }` |
| Boolean | `{ BOOL = true }` | `{ BOOL = true }` |
| Lista | `{ L = [...] }` | `{ L = [{ S = "a" }, { S = "b" }] }` |
| Mapa | `{ M = {...} }` | `{ M = { key = { S = "val" } } }` |
| Null | `{ NULL = true }` | (para valores vacíos) |

**¿Cuándo es buena idea insertar datos con Terraform?**

- Datos de configuración que rara vez cambian
- Datos de seed inicial para pruebas
- Registros de administración

**¿Cuándo NO usar Terraform para insertar datos?**

- Datos generados por usuarios (pedidos, registros, etc.)
- Cualquier cosa que cambie frecuentemente en runtime

---

## Múltiples tablas con `for_each` y tipo `object`

```hcl
variable "tablas_config" {
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
```

**`map(object({...}))`**: un tipo de variable más avanzado. Es un mapa donde cada valor es un objeto con propiedades tipadas.

```
variable tablas_config = {
  "sesiones" → { hash_key = "session_id", range_key = "timestamp" }
  "auditoria" → { hash_key = "evento_id", range_key = "fecha" }
}
```

Al iterar con `for_each`:
- `each.key` → `"sesiones"` o `"auditoria"`
- `each.value.hash_key` → `"session_id"` o `"evento_id"`
- `each.value.range_key` → `"timestamp"` o `"fecha"`

Esto crea 2 tablas completamente configuradas desde una sola variable.

---

## Outputs

```hcl
output "tabla_pedidos_indices" {
  description = "Índices GSI de la tabla pedidos"
  value       = [for gsi in aws_dynamodb_table.pedidos.global_secondary_index : gsi.name]
}

output "todas_las_tablas" {
  value = concat(
    [aws_dynamodb_table.usuarios.name],
    [aws_dynamodb_table.pedidos.name],
    [aws_dynamodb_table.productos.name],
    [for t in aws_dynamodb_table.extras : t.name]
  )
}
```

El output `tabla_pedidos_indices` usa una expresión `for` para extraer solo los nombres de los GSI de la tabla, demostrando cómo navegar atributos anidados de un recurso.

---

## Comandos para verificar en LocalStack

```bash
# Listar todas las tablas
aws --endpoint-url=http://localhost:4566 dynamodb list-tables

# Ver la estructura de una tabla
aws --endpoint-url=http://localhost:4566 dynamodb describe-table \
  --table-name lab-dev-usuarios

# Consultar ítems insertados
aws --endpoint-url=http://localhost:4566 dynamodb scan \
  --table-name lab-dev-usuarios

# Consultar un ítem específico
aws --endpoint-url=http://localhost:4566 dynamodb get-item \
  --table-name lab-dev-usuarios \
  --key '{"user_id": {"S": "USR-001"}}'
```

---

## Ejercicios propuestos

1. Agrega un tercer `aws_dynamodb_table_item` con un nuevo usuario.

2. Agrega una nueva tabla `"logs"` al mapa `tablas_config`. Ejecuta `terraform plan`. ¿Cuántos recursos nuevos aparecen?

3. Cambia la tabla `productos` de `PROVISIONED` a `PAY_PER_REQUEST` y ejecuta `terraform plan`. ¿Terraform destruye y recrea la tabla, o solo la modifica?

4. Usa `terraform state show aws_dynamodb_table.pedidos` y examina cómo se representan los GSI en el state.

5. Modifica la tabla `pedidos` para agregar un nuevo GSI que tenga como `hash_key` el campo `user_id` y como `range_key` el campo `estado`. Recuerda que `user_id` ya está declarado como `attribute`.
