# Módulo 04 — IAM · Identidad y Gestión de Acceso

## ¿Qué vas a aprender?

- Qué son los Roles, Políticas y Usuarios IAM
- Crear un rol IAM y definir quién puede asumirlo (`assume_role_policy`)
- Escribir políticas IAM con `data "aws_iam_policy_document"` (forma recomendada)
- Escribir políticas con `jsonencode` y con heredoc `<<-EOF`
- Adjuntar políticas a roles (`aws_iam_role_policy_attachment`)
- Crear políticas inline dentro de un rol (`aws_iam_role_policy`)
- Crear usuarios y grupos IAM
- Crear múltiples usuarios con `for_each`
- Condiciones en políticas IAM

---

## Cómo ejecutar este módulo

```bash
docker-compose up -d
cd modulo-04-iam
terraform init
terraform apply -auto-approve
terraform output s3_policy_json   # Ver el JSON generado de la política
terraform destroy
```

---

## Concepto previo — IAM: el sistema de permisos de AWS

IAM (Identity and Access Management) controla quién puede hacer qué en tu cuenta de AWS.

Tiene tres conceptos principales:

```
¿QUIÉN puede actuar?        → Usuarios (personas) o Roles (servicios/apps)
¿QUÉ puede hacer?           → Políticas (listas de permisos: Allow/Deny)
¿SOBRE QUÉ recurso?         → ARN del recurso (un bucket, una tabla, etc.)
```

Ejemplo de política en lenguaje humano:
```
"Lambda puede leer y escribir en buckets S3 que empiecen por 'lab-dev-'"
```

En JSON:
```json
{
  "Effect": "Allow",
  "Action": ["s3:GetObject", "s3:PutObject"],
  "Resource": "arn:aws:s3:::lab-dev-*/*"
}
```

---

## Recurso 1 — Rol IAM para Lambda

Un rol define "quién puede asumir estos permisos". El `assume_role_policy` es la política de confianza: dice qué entidad puede "ponerse" este rol.

### Forma recomendada: `data "aws_iam_policy_document"`

```hcl
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
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
```

**¿Por qué usar `data "aws_iam_policy_document"`?**

- Es HCL nativo, con autocompletado y validación de sintaxis
- Terraform genera el JSON correcto por ti
- El atributo `.json` devuelve el JSON listo para usar
- Es más legible que escribir JSON crudo

**¿Qué significa este bloque de confianza?**

```
"Permite que el servicio Lambda (lambda.amazonaws.com) asuma este rol"
```

Cuando Lambda ejecuta tu función, necesita un rol con permisos. Este `assume_role_policy` le da permiso a Lambda para usarlo.

---

## Recurso 2 — Política IAM con múltiples sentencias

```hcl
data "aws_iam_policy_document" "s3_full_access" {

  # Sentencia 1: Permitir listar buckets
  statement {
    sid    = "ListarBuckets"
    effect = "Allow"
    actions = [
      "s3:ListAllMyBuckets",
      "s3:GetBucketLocation",
    ]
    resources = ["arn:aws:s3:::*"]
  }

  # Sentencia 2: Acceso completo a buckets del proyecto
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

  # Sentencia 3: DENEGAR borrar buckets (override)
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
```

**Puntos clave:**

**`sid`**: Statement ID. Un identificador opcional para la sentencia, útil para documentar y debuggear.

**ARN con wildcards**:
```
arn:aws:s3:::lab-dev-*       → cualquier bucket que empiece por "lab-dev-"
arn:aws:s3:::lab-dev-*/*     → cualquier objeto dentro de esos buckets
```

**`Deny` tiene prioridad sobre `Allow`**: Si una sentencia dice `Allow` y otra dice `Deny` para la misma acción y recurso, `Deny` siempre gana. Aquí usamos `Deny` para prohibir borrar buckets aunque otro `Allow` lo permita.

---

## Adjuntar una política a un rol

```hcl
resource "aws_iam_role_policy_attachment" "lambda_s3" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.s3_policy.arn
}
```

**¿Qué hace?**

Conecta la política con el rol. Ahora el rol de Lambda puede hacer todo lo que la política de S3 permite.

Nótese la separación de responsabilidades:
- `aws_iam_policy` → define los permisos
- `aws_iam_role` → define quién puede asumir los permisos
- `aws_iam_role_policy_attachment` → conecta ambos

---

## Política inline directamente en el rol

```hcl
resource "aws_iam_role_policy" "lambda_logs" {
  name = "${local.prefijo}-lambda-logs"
  role = aws_iam_role.lambda_role.id

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
```

**Diferencia entre política adjunta y política inline:**

| | Política adjunta (`aws_iam_policy`) | Política inline (`aws_iam_role_policy`) |
|---|---|---|
| **Reutilizable** | Sí, puedes adjuntarla a múltiples roles | No, está ligada a un solo rol |
| **Visible en consola** | Sí, como política independiente | Solo se ve dentro del rol |
| **Cuándo usar** | Permisos comunes a varios recursos | Permisos específicos y únicos de ese rol |
| **Límite por rol** | 10 políticas adjuntas | Sin límite pero no recomendable abusar |

---

## Las 3 formas de escribir políticas IAM en Terraform

Este módulo muestra las tres opciones para que conozcas todas.

### Forma 1 — `data "aws_iam_policy_document"` (RECOMENDADA)

```hcl
data "aws_iam_policy_document" "ejemplo" {
  statement {
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = ["arn:aws:s3:::mi-bucket/*"]
  }
}

resource "aws_iam_role" "mi_rol" {
  assume_role_policy = data.aws_iam_policy_document.ejemplo.json
}
```

Ventajas: validación automática, autocompletado, HCL nativo.

### Forma 2 — `jsonencode()` (buena para políticas simples)

```hcl
resource "aws_iam_role_policy" "mi_policy" {
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "arn:aws:s3:::mi-bucket/*"
    }]
  })
}
```

Ventajas: compacto, sigue siendo HCL, fácil de leer.

### Forma 3 — Heredoc `<<-EOF` (forma clásica, menos recomendada)

```hcl
resource "aws_iam_role" "ec2_role" {
  assume_role_policy = <<-EOF
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": { "Service": "ec2.amazonaws.com" },
          "Action": "sts:AssumeRole"
        }
      ]
    }
  EOF
}
```

Desventajas: es JSON crudo, sin validación, más propenso a errores de tipeo.

---

## Política con condiciones

```hcl
data "aws_iam_policy_document" "dynamodb_restricted" {
  statement {
    sid    = "AccesoDynamoDB"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
    ]
    resources = [
      "arn:aws:dynamodb:us-east-1:*:table/${local.prefijo}-*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["us-east-1"]
    }
  }
}
```

**¿Qué hace la condición?**

Restringe aún más el permiso: solo se puede usar esta política si la petición llega desde `us-east-1`. Aunque el usuario tenga el permiso, si intenta usarlo desde otra región, AWS lo deniega.

Las condiciones son una capa extra de seguridad muy usada en entornos de producción.

---

## Usuario IAM y grupos

```hcl
# Crear usuario
resource "aws_iam_user" "desarrollador" {
  name = "${local.prefijo}-desarrollador"
  tags = merge(local.tags, { tipo = "desarrollador" })
}

# Adjuntar política al usuario (igual que con roles)
resource "aws_iam_user_policy_attachment" "dev_s3" {
  user       = aws_iam_user.desarrollador.name
  policy_arn = aws_iam_policy.s3_policy.arn
}

# Crear grupo
resource "aws_iam_group" "devops" {
  name = "${local.prefijo}-equipo-devops"
}

# Añadir usuario al grupo
resource "aws_iam_group_membership" "devops_miembros" {
  name  = "devops-membership"
  group = aws_iam_group.devops.name
  users = [aws_iam_user.desarrollador.name]
}

# Adjuntar política al grupo (se hereda a todos los miembros)
resource "aws_iam_group_policy_attachment" "devops_s3" {
  group      = aws_iam_group.devops.name
  policy_arn = aws_iam_policy.s3_policy.arn
}
```

**Jerarquía de permisos IAM:**

```
Política
  ↑
  Adjunta a → Usuario (permisos directos)
  Adjunta a → Grupo (todos los miembros heredan)
  Adjunta a → Rol (servicios/aplicaciones lo asumen)
```

---

## Múltiples usuarios con `for_each`

```hcl
variable "usuarios" {
  type = map(object({
    grupo = string
  }))
  default = {
    "ana-garcia"    = { grupo = "devops" }
    "luis-martinez" = { grupo = "devops" }
    "carlos-lopez"  = { grupo = "devops" }
  }
}

resource "aws_iam_user" "equipo" {
  for_each = var.usuarios

  name = "${local.prefijo}-${each.key}"
  tags = merge(local.tags, { miembro = each.key })
}
```

Para agregar nuevos usuarios, solo editas el mapa `usuarios`. Terraform crea los usuarios nuevos sin tocar los existentes.

---

## Outputs

```hcl
output "lambda_role_arn" {
  value = aws_iam_role.lambda_role.arn
}

output "s3_policy_json" {
  description = "JSON de la política de S3 (para revisar)"
  value       = data.aws_iam_policy_document.s3_full_access.json
}
```

El output `s3_policy_json` es muy útil durante el aprendizaje: puedes ejecutar `terraform output s3_policy_json` y ver exactamente qué JSON genera Terraform a partir de tu código HCL.

---

## Comandos para verificar en LocalStack

```bash
# Ver roles creados
aws --endpoint-url=http://localhost:4566 iam list-roles

# Ver políticas adjuntas a un rol
aws --endpoint-url=http://localhost:4566 iam list-attached-role-policies \
  --role-name lab-dev-lambda-role

# Ver el contenido de una política
aws --endpoint-url=http://localhost:4566 iam get-policy-version \
  --policy-arn <ARN_DE_LA_POLITICA> \
  --version-id v1

# Ver usuarios creados
aws --endpoint-url=http://localhost:4566 iam list-users

# Ver el JSON de la política en el output de Terraform
terraform output s3_policy_json
```

---

## Ejercicios propuestos

1. Agrega una nueva condición a la política de DynamoDB que solo permita acceso entre las 8am y las 6pm usando `aws:CurrentTime`.

2. Crea un nuevo usuario `"pedro-sanchez"` agregándolo al mapa `usuarios` y ejecuta `terraform apply`. Verifica que solo se crea ese usuario y los demás no se modifican.

3. Crea un nuevo rol para EC2 que tenga permisos de solo lectura en S3. Usa `data "aws_iam_policy_document"`.

4. Ejecuta `terraform output s3_policy_json` y examina el JSON generado. ¿Puedes ver las 3 sentencias (Allow-Allow-Deny)?

5. Adjunta también la política de DynamoDB al usuario `desarrollador` usando `aws_iam_user_policy_attachment`.
