# Módulo 02 — S3 Buckets · Almacenamiento de objetos

## ¿Qué vas a aprender?

- Crear buckets S3 simples
- Activar versionado en un bucket
- Configurar un sitio web estático en S3
- Subir archivos (objetos) directamente desde Terraform
- Crear múltiples buckets con `for_each`
- Generar contenido JSON dinámico con `jsonencode`
- Usar `data sources` para leer recursos existentes
- Usar `depends_on` para declarar dependencias explícitas
- Concatenar listas con `concat`

---

## Cómo ejecutar este módulo

```bash
docker-compose up -d          # Levanta LocalStack
cd modulo-02-s3
terraform init
terraform apply -auto-approve
terraform state list
terraform output
terraform destroy
```

---

## Concepto previo — ¿Qué es S3?

S3 (Simple Storage Service) es el servicio de almacenamiento de archivos de AWS. Funciona como un disco duro en la nube donde guardas objetos (archivos). No tiene carpetas reales, pero usa rutas con `/` como convención.

```
bucket: mi-empresa-datos
├── config/settings.json
├── imagenes/logo.png
└── reportes/2026/enero.pdf
```

---

## Estructura del `main.tf`

### Provider — Solo expone los endpoints necesarios

```hcl
provider "aws" {
  region     = "us-east-1"
  access_key = "test"
  secret_key = "test"
  ...
  endpoints {
    s3  = "http://localhost:4566"
    sts = "http://localhost:4566"
  }
}
```

Este módulo solo necesita S3, por eso `endpoints` solo declara `s3` y `sts`. En el módulo 01 había muchos más porque trabajaba con varios servicios.

---

## Variables y locals

```hcl
variable "nombre_proyecto" {
  type    = string
  default = "lab-terraform"
}

variable "entorno" {
  type    = string
  default = "dev"
}

locals {
  prefijo = "${var.nombre_proyecto}-${var.entorno}"
  # Resultado: "lab-terraform-dev"

  tags = {
    proyecto = var.nombre_proyecto
    entorno  = var.entorno
    modulo   = "02-s3"
  }
}
```

El `prefijo` se usa en los nombres de todos los buckets para que sean únicos y reconocibles.

---

## Recurso 1 — Bucket S3 básico

```hcl
resource "aws_s3_bucket" "principal" {
  bucket = "${local.prefijo}-datos-principales"
  tags   = local.tags
}
```

**¿Qué hace?**

Crea un bucket vacío en S3. El nombre del bucket debe ser único globalmente en AWS (en LocalStack esto no importa). El nombre resultante sería `lab-terraform-dev-datos-principales`.

---

## Recurso 2 — Versionado del bucket

```hcl
resource "aws_s3_bucket_versioning" "principal" {
  bucket = aws_s3_bucket.principal.id

  versioning_configuration {
    status = "Enabled"
  }
}
```

**¿Qué hace?**

Activa el historial de versiones para el bucket. Con versionado activado:

- Si subes `foto.jpg` dos veces, S3 guarda **las dos versiones**
- Si alguien borra un archivo, puedes recuperar la versión anterior
- Fundamental para disaster recovery (ver módulo 16)

**Punto clave**: En Terraform moderno, el versionado es un **recurso separado**, no una propiedad del bucket. Por eso ves dos bloques `resource` distintos. `aws_s3_bucket.principal.id` referencia el ID del bucket ya creado.

---

## Recurso 3 — Bucket para website estático

```hcl
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
```

**¿Qué hace?**

Configura el bucket para servir archivos HTML como si fuera un servidor web. Cuando alguien visita la URL del bucket:

- Sirve `index.html` por defecto
- Sirve `error.html` si la ruta no existe

---

## Recurso 4 — Subir objetos (archivos) con Terraform

```hcl
resource "aws_s3_object" "index_html" {
  bucket       = aws_s3_bucket.website.id
  key          = "index.html"
  content      = <<-HTML
    <!DOCTYPE html>
    <html>
    <head><title>Lab Terraform</title></head>
    <body>
      <h1>¡Hola desde Terraform + LocalStack!</h1>
      <p>Entorno: ${var.entorno}</p>
    </body>
    </html>
  HTML
  content_type = "text/html"

  tags = local.tags
}
```

**¿Qué hace?**

Sube un archivo HTML directamente al bucket desde el código Terraform, sin necesidad de herramientas externas.

- `key` → La ruta dentro del bucket (como el nombre del archivo)
- `content` → El contenido del archivo escrito inline usando heredoc `<<-HTML`
- `content_type` → Le dice a S3 que es HTML para que el navegador lo renderice correctamente
- `${var.entorno}` dentro del heredoc → ¡La interpolación funciona dentro del contenido!

**Heredoc `<<-HTML ... HTML`**: es una forma de escribir texto multilínea en HCL. El `-` después de `<<` permite que el texto tenga indentación sin que Terraform la incluya.

---

## Recurso 5 — Múltiples buckets con `for_each`

```hcl
variable "buckets_adicionales" {
  type = map(string)
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
```

**¿Qué crea?**

3 buckets, uno por cada entrada del mapa:

```
lab-terraform-dev-imagenes   (tag descripcion = "Almacén de imágenes")
lab-terraform-dev-backups    (tag descripcion = "Copias de seguridad")
lab-terraform-dev-temporal   (tag descripcion = "Archivos temporales")
```

Para agregar un nuevo bucket, solo añades una línea al mapa en `default` o en tu `terraform.tfvars`.

---

## Recurso 6 — Subir JSON generado dinámicamente

```hcl
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

  depends_on = [aws_s3_bucket_versioning.principal]
}
```

**Puntos clave:**

**`jsonencode()`**: convierte un objeto HCL a una cadena JSON. Muy útil para generar archivos de configuración dinámicos.

```hcl
jsonencode({
  nombre = "terraform"
  activo = true
  lista  = [1, 2, 3]
})

# Resultado:
# {"nombre":"terraform","activo":true,"lista":[1,2,3]}
```

**`[for k, b in aws_s3_bucket.adicionales : b.bucket]`**: liste comprensión que extrae el nombre de cada bucket adicional y genera una lista.

**`depends_on`**: le dice a Terraform que este recurso debe crearse **después** de que el versionado esté configurado. Terraform suele detectar dependencias automáticamente (cuando un recurso referencia a otro), pero a veces necesitas declararlas manualmente cuando la relación no es obvia.

---

## Data Source — Leer información de recursos existentes

```hcl
data "aws_s3_bucket" "consulta_principal" {
  bucket = aws_s3_bucket.principal.id

  depends_on = [aws_s3_bucket.principal]
}
```

**¿Qué es un data source?**

A diferencia de `resource` (que crea), `data` **solo lee** información de algo que ya existe. Es como hacer una consulta.

- Puedes leer el ARN, la región o los tags de un bucket que ya existía antes de que Terraform lo creara
- También sirve para leer recursos creados fuera de Terraform (por otro equipo, por la consola web, etc.)

**Diferencia clave:**

```hcl
resource "aws_s3_bucket" "nuevo" { ... }   # CREA un bucket

data "aws_s3_bucket" "existente" {         # CONSULTA un bucket que ya existe
  bucket = "nombre-del-bucket-ya-creado"
}
```

---

## Outputs

```hcl
output "bucket_principal_arn" {
  value = aws_s3_bucket.principal.arn
}

output "website_url" {
  value = aws_s3_bucket_website_configuration.website.website_endpoint
}

output "buckets_adicionales" {
  value = { for k, b in aws_s3_bucket.adicionales : k => b.arn }
}

output "todos_los_buckets" {
  value = concat(
    [aws_s3_bucket.principal.bucket],
    [aws_s3_bucket.website.bucket],
    [aws_s3_bucket.logs.bucket],
    [for b in aws_s3_bucket.adicionales : b.bucket]
  )
}
```

**`concat()`**: une varias listas en una sola:

```hcl
concat(["a", "b"], ["c", "d"])
# Resultado: ["a", "b", "c", "d"]
```

El último output construye una lista con todos los buckets del módulo mezclando recursos individuales y los creados con `for_each`.

---

## Recursos que crea este módulo

| Recurso | Nombre en LocalStack |
|---------|---------------------|
| Bucket principal | `lab-terraform-dev-datos-principales` |
| Versionado | (asociado al bucket principal) |
| Bucket website | `lab-terraform-dev-website` |
| Website config | (asociado al bucket website) |
| index.html | objeto en el bucket website |
| error.html | objeto en el bucket website |
| Bucket logs | `lab-terraform-dev-logs` |
| config/settings.json | objeto en el bucket principal |
| Bucket imagenes | `lab-terraform-dev-imagenes` |
| Bucket backups | `lab-terraform-dev-backups` |
| Bucket temporal | `lab-terraform-dev-temporal` |

---

## Comandos útiles para verificar en LocalStack

```bash
# Listar todos los buckets
aws --endpoint-url=http://localhost:4566 s3 ls

# Ver objetos dentro de un bucket
aws --endpoint-url=http://localhost:4566 s3 ls s3://lab-terraform-dev-website/

# Descargar un objeto
aws --endpoint-url=http://localhost:4566 s3 cp \
  s3://lab-terraform-dev-website/index.html ./index.html

# Ver el estado de versionado de un bucket
aws --endpoint-url=http://localhost:4566 s3api get-bucket-versioning \
  --bucket lab-terraform-dev-datos-principales
```

---

## Ejercicios propuestos

1. Agrega `"archivos" = "Documentos internos"` al mapa `buckets_adicionales` y ejecuta `terraform plan`. ¿Cuántos recursos nuevos aparecen?

2. Modifica el contenido del `index.html` y ejecuta `terraform plan`. ¿Qué recurso detecta el cambio?

3. Ejecuta `terraform state show aws_s3_bucket.principal` y examina todos los atributos que Terraform guarda en el state.

4. Elimina solo el bucket de logs sin tocar el resto:
   ```bash
   terraform destroy -target=aws_s3_bucket.logs
   ```
   ¿Qué pasa cuando haces `terraform plan` después?

5. Crea un output `total_buckets` que devuelva el número total de buckets usando `length()` aplicado al output `todos_los_buckets`.
