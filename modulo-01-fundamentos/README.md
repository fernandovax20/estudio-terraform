# Módulo 01 — Fundamentos de Terraform

## ¿Qué vas a aprender?

- Qué es un archivo `.tf` y cómo se estructura
- Variables de entrada (`variable`)
- Variables locales calculadas (`locals`)
- Tipos de datos: `string`, `number`, `bool`, `list`, `map`
- Crear recursos (`resource`)
- Repetir recursos con `count` y `for_each`
- Exportar valores (`output`)
- Interpolación de strings y condicionales

---

## Cómo ejecutar este módulo

```bash
# 1. Levanta LocalStack (desde la raíz del proyecto)
docker-compose up -d

# 2. Entra al módulo
cd modulo-01-fundamentos

# 3. Descarga el provider de AWS
terraform init

# 4. Previsualiza qué va a crear
terraform plan

# 5. Crea los recursos
terraform apply
# Escribe "yes" cuando lo pida

# 6. Mira los resultados
terraform output

# 7. Limpia todo cuando termines
terraform destroy
```

---

## Estructura del archivo `main.tf`

El archivo está dividido en 6 bloques principales. Vamos uno por uno.

---

## Bloque 1 — `terraform {}` · Requisitos del proyecto

```hcl
terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

**¿Para qué sirve?**

Es la "ficha técnica" del proyecto. Le dice a Terraform:

- `required_version = ">= 1.0.0"` → Necesitas Terraform 1.0 o más nuevo
- `required_providers` → Declara los plugins que necesitas. Aquí usamos el provider oficial de AWS
- `source = "hashicorp/aws"` → Se descarga del registro oficial de HashiCorp
- `version = "~> 5.0"` → Usa la versión 5.x (acepta 5.1, 5.2... pero no 6.0)

Cuando ejecutas `terraform init`, Terraform lee este bloque y descarga los providers a la carpeta `.terraform/`.

---

## Bloque 2 — `provider "aws" {}` · Conexión con LocalStack

```hcl
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
    lambda   = "http://localhost:4566"
    sqs      = "http://localhost:4566"
    sns      = "http://localhost:4566"
    ec2      = "http://localhost:4566"
    sts      = "http://localhost:4566"
    ssm      = "http://localhost:4566"
  }
}
```

**¿Para qué sirve?**

Configura la conexión con AWS. En este laboratorio, en vez de conectar con AWS real (que cuesta dinero), lo redirigimos a LocalStack que corre en tu computadora.

| Línea | Qué hace |
|-------|----------|
| `region = "us-east-1"` | Región donde se crean los recursos |
| `access_key = "test"` | Credencial falsa (LocalStack no la valida) |
| `secret_key = "test"` | Credencial falsa |
| `skip_credentials_validation = true` | No intentes validar las credenciales |
| `skip_metadata_api_check = true` | No consultes el servicio de metadatos EC2 |
| `skip_requesting_account_id = true` | No pidas el ID de cuenta AWS |
| `endpoints { ... }` | **Lo más importante**: redirige cada servicio a `localhost:4566` |

**Sin `endpoints`:** Terraform llamaría a `https://s3.amazonaws.com` (AWS real → costo real)  
**Con `endpoints`:** Terraform llama a `http://localhost:4566` (LocalStack → gratis)

---

## Bloque 3 — `variable {}` · Variables de entrada

Las variables son parámetros que puedes cambiar sin tocar el código.

### Variable tipo `string`

```hcl
variable "proyecto" {
  description = "Nombre del proyecto"
  type        = string
  default     = "mi-lab-terraform"
}
```

- `description` → Documentación de para qué sirve
- `type = string` → Acepta solo texto
- `default` → Valor por defecto si el usuario no pasa ninguno

**Cómo acceder a ella en el código:**

```hcl
name = var.proyecto   # Devuelve "mi-lab-terraform"
```

**Cómo cambiar el valor al ejecutar:**

```bash
terraform apply -var="proyecto=mi-app"
```

---

### Variable con validación

```hcl
variable "entorno" {
  description = "Entorno de despliegue"
  type        = string
  default     = "desarrollo"

  validation {
    condition     = contains(["desarrollo", "staging", "produccion"], var.entorno)
    error_message = "El entorno debe ser: desarrollo, staging o produccion."
  }
}
```

El bloque `validation` hace que Terraform rechace valores inválidos **antes** de crear cualquier recurso.

```bash
terraform apply -var="entorno=testing"
# ERROR: El entorno debe ser: desarrollo, staging o produccion.
```

---

### Tipos de datos disponibles

```hcl
# Número
variable "numero_de_buckets" {
  type    = number
  default = 2
}

# Booleano
variable "habilitar_logs" {
  type    = bool
  default = true
}

# Mapa (diccionario clave-valor)
variable "tags_comunes" {
  type = map(string)
  default = {
    "proyecto"   = "estudio-terraform"
    "creado_por" = "terraform"
    "entorno"    = "local"
  }
}

# Lista
variable "zonas_disponibles" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}
```

| Tipo | Ejemplo | Acceso |
|------|---------|--------|
| `string` | `"hola"` | `var.nombre` |
| `number` | `42` | `var.numero_de_buckets` |
| `bool` | `true` | `var.habilitar_logs` |
| `list(string)` | `["a","b"]` | `var.zonas_disponibles[0]` |
| `map(string)` | `{key = "val"}` | `var.tags_comunes["proyecto"]` |

---

## Bloque 4 — `locals {}` · Variables locales calculadas

Los `locals` son variables que **calculas internamente**. El usuario no puede cambiarlas con `-var`. Se usan para centralizar lógica y evitar repetición.

```hcl
locals {
  # 1. Concatenar strings (interpolación)
  nombre_completo = "${var.proyecto}-${var.entorno}"
  # Resultado: "mi-lab-terraform-desarrollo"

  # 2. Condicional (operador ternario)
  nivel_logs = var.habilitar_logs ? "INFO" : "NONE"
  # Si habilitar_logs=true → "INFO", si es false → "NONE"

  # 3. Combinar dos diccionarios (merge)
  tags_finales = merge(var.tags_comunes, {
    "nombre" = local.nombre_completo
    "fecha"  = timestamp()
  })

  # 4. Transformar lista en mapa (expresión for)
  zonas_map = { for idx, zona in var.zonas_disponibles : "zona-${idx}" => zona }
}
```

**¿Cómo se accede a un local?**

```hcl
name = local.nombre_completo   # Siempre con prefijo "local."
```

### El condicional explicado

```hcl
nivel_logs = var.habilitar_logs ? "INFO" : "NONE"
#            ↑ condición         ↑ si true  ↑ si false
```

Equivale a esto en cualquier lenguaje de programación:

```python
if habilitar_logs == True:
    nivel_logs = "INFO"
else:
    nivel_logs = "NONE"
```

### El `merge` explicado

```hcl
tags_finales = merge(var.tags_comunes, {
  "nombre" = local.nombre_completo
  "fecha"  = timestamp()
})
```

Une dos mapas en uno solo. Si hay claves repetidas, el segundo mapa gana:

```
# Entrada 1 (var.tags_comunes)
{
  "proyecto"   = "estudio-terraform"
  "creado_por" = "terraform"
  "entorno"    = "local"
}

# Entrada 2 (mapa inline)
{
  "nombre" = "mi-lab-terraform-desarrollo"
  "fecha"  = "2026-04-01T10:00:00Z"
}

# Resultado (tags_finales)
{
  "proyecto"   = "estudio-terraform"
  "creado_por" = "terraform"
  "entorno"    = "local"
  "nombre"     = "mi-lab-terraform-desarrollo"
  "fecha"      = "2026-04-01T10:00:00Z"
}
```

### La expresión `for` en locals

```hcl
zonas_map = { for idx, zona in var.zonas_disponibles : "zona-${idx}" => zona }
```

Convierte una lista en un mapa:

```
# Entrada
["us-east-1a", "us-east-1b", "us-east-1c"]

# Salida
{
  "zona-0" = "us-east-1a"
  "zona-1" = "us-east-1b"
  "zona-2" = "us-east-1c"
}
```

---

## Bloque 5 — `resource {}` · Los recursos reales

Los recursos son **lo que Terraform crea en AWS/LocalStack**. Este módulo usa `aws_ssm_parameter` (parámetros SSM) como ejemplo porque son sencillos: solo guardan un nombre y un valor.

### Recurso simple

```hcl
resource "aws_ssm_parameter" "configuracion_proyecto" {
  name  = "/${local.nombre_completo}/config/nombre"
  type  = "String"
  value = local.nombre_completo

  tags = local.tags_finales
}
```

**Desglose:**

- `"aws_ssm_parameter"` → El tipo de recurso (define qué servicio de AWS se usa)
- `"configuracion_proyecto"` → Nombre lógico que tú eliges para referenciarlo dentro del código
- `name` → El nombre del parámetro tal como aparecerá en AWS
- `type = "String"` → Tipo de dato del parámetro SSM
- `value` → El valor almacenado
- `tags` → Etiquetas para identificar y clasificar el recurso

**Resultado en LocalStack:**

```
Clave:  /mi-lab-terraform-desarrollo/config/nombre
Valor:  mi-lab-terraform-desarrollo
```

---

### Recurso con `count` · Crear N copias

```hcl
resource "aws_ssm_parameter" "parametros_zonas" {
  count = length(var.zonas_disponibles)   # 3

  name  = "/${local.nombre_completo}/zonas/zona-${count.index}"
  type  = "String"
  value = var.zonas_disponibles[count.index]

  tags = local.tags_finales
}
```

`count = 3` hace que Terraform cree 3 copias del recurso. Cada copia usa `count.index` (0, 1, 2):

```
# Iteración 0  →  count.index = 0
name  = "/mi-lab-terraform-desarrollo/zonas/zona-0"
value = "us-east-1a"

# Iteración 1  →  count.index = 1
name  = "/mi-lab-terraform-desarrollo/zonas/zona-1"
value = "us-east-1b"

# Iteración 2  →  count.index = 2
name  = "/mi-lab-terraform-desarrollo/zonas/zona-2"
value = "us-east-1c"
```

---

### Recurso con `for_each` · Iterar sobre un mapa

```hcl
resource "aws_ssm_parameter" "tags_individuales" {
  for_each = var.tags_comunes

  name  = "/${local.nombre_completo}/tags/${each.key}"
  type  = "String"
  value = each.value

  tags = local.tags_finales
}
```

`for_each` itera sobre cada entrada del mapa `var.tags_comunes`. Usa `each.key` y `each.value`:

```
# Iteración "proyecto"
each.key   = "proyecto"
each.value = "estudio-terraform"
→ name = "/mi-lab-terraform-desarrollo/tags/proyecto"

# Iteración "creado_por"
each.key   = "creado_por"
each.value = "terraform"
→ name = "/mi-lab-terraform-desarrollo/tags/creado_por"

# Iteración "entorno"
each.key   = "entorno"
each.value = "local"
→ name = "/mi-lab-terraform-desarrollo/tags/entorno"
```

---

### `count` vs `for_each` — ¿Cuándo usar cada uno?

| | `count` | `for_each` |
|---|---------|-----------|
| **Entrada** | Número o lista | Mapa o set |
| **Índice** | Numérico `[0]`, `[1]` | Por clave `["nombre"]` |
| **Cuándo usar** | Copias idénticas | Recursos con identidad propia |
| **Problema potencial** | Reindexación si quitas uno del medio | Sin este problema |

**¿Por qué `for_each` es más seguro?**

Si usas `count` con 3 recursos `[A, B, C]` y eliminas `B`, Terraform ve que `C` pasó del índice `[2]` al `[1]`. Lo interpreta como "destruye el índice 1 y 2, crea un nuevo índice 1". Resultado: destruye y recrea `C` innecesariamente.

Con `for_each`, los recursos se identifican por clave string estable. Eliminar `B` no afecta a `C`.

---

## Bloque 6 — `output {}` · Valores de salida

Los outputs muestran información en la terminal después de `terraform apply`. También sirven para pasar datos entre módulos.

### Output simple

```hcl
output "nombre_proyecto" {
  description = "Nombre completo del proyecto"
  value       = local.nombre_completo
}
```

Consultarlo:

```bash
terraform output nombre_proyecto
# mi-lab-terraform-desarrollo
```

### Output que transforma una lista

```hcl
output "parametros_zonas" {
  description = "Parámetros de zonas creados con count"
  value       = [for p in aws_ssm_parameter.parametros_zonas : p.name]
}
```

Toma todos los recursos del `count` y extrae solo el atributo `.name` de cada uno:

```json
[
  "/mi-lab-terraform-desarrollo/zonas/zona-0",
  "/mi-lab-terraform-desarrollo/zonas/zona-1",
  "/mi-lab-terraform-desarrollo/zonas/zona-2"
]
```

### Output que transforma un mapa

```hcl
output "parametros_tags" {
  value = { for k, p in aws_ssm_parameter.tags_individuales : k => p.name }
}
```

Devuelve un mapa con la clave del tag apuntando al nombre del parámetro:

```json
{
  "proyecto": "/mi-lab-terraform-desarrollo/tags/proyecto",
  "creado_por": "/mi-lab-terraform-desarrollo/tags/creado_por",
  "entorno": "/mi-lab-terraform-desarrollo/tags/entorno"
}
```

---

## Recursos que crea este módulo

Al ejecutar `terraform apply` se crean **9 parámetros SSM en LocalStack**:

| # | Nombre | Valor | Creado con |
|---|--------|-------|-----------|
| 1 | `/mi-lab-terraform-desarrollo/config/nombre` | `mi-lab-terraform-desarrollo` | recurso simple |
| 2 | `/mi-lab-terraform-desarrollo/config/entorno` | `desarrollo` | recurso simple |
| 3 | `/mi-lab-terraform-desarrollo/config/nivel-logs` | `INFO` | recurso simple |
| 4 | `/mi-lab-terraform-desarrollo/zonas/zona-0` | `us-east-1a` | `count` |
| 5 | `/mi-lab-terraform-desarrollo/zonas/zona-1` | `us-east-1b` | `count` |
| 6 | `/mi-lab-terraform-desarrollo/zonas/zona-2` | `us-east-1c` | `count` |
| 7 | `/mi-lab-terraform-desarrollo/tags/proyecto` | `estudio-terraform` | `for_each` |
| 8 | `/mi-lab-terraform-desarrollo/tags/creado_por` | `terraform` | `for_each` |
| 9 | `/mi-lab-terraform-desarrollo/tags/entorno` | `local` | `for_each` |

Verificar en LocalStack:

```bash
aws --endpoint-url=http://localhost:4566 ssm get-parameters-by-path \
  --path "/mi-lab-terraform-desarrollo" --recursive
```

---

## Comandos de Terraform para practicar

```bash
# Ver qué recursos existen en el state
terraform state list

# Ver el detalle de un recurso específico
terraform state show aws_ssm_parameter.configuracion_proyecto

# Cambiar el entorno y ver qué cambia
terraform plan -var="entorno=staging"

# Ver todos los outputs en JSON
terraform output -json

# Ver el estado completo
terraform show
```

---

## Ejercicios propuestos

1. Cambia `entorno` a `"staging"` con `-var` y ejecuta `terraform plan`. ¿Qué recursos aparecen como modificados?

2. Agrega una nueva `variable "version"` de tipo `string` con default `"1.0.0"` y crea un nuevo `aws_ssm_parameter` que la use.

3. Aumenta `numero_de_buckets` a `5` y observa el plan. ¿Se modifica algo aunque esa variable no se use en ningún recurso todavía?

4. Crea un output llamado `total_parametros` que devuelva el número total de parámetros creados usando la función `length()`.

5. Ejecuta `terraform state list` y luego `terraform state show` para cada recurso. Examina qué atributos guarda Terraform de cada uno.
