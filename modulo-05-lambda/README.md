# Módulo 05 — Lambda · Funciones Serverless

## ¿Qué vas a aprender?

- Qué es serverless y por qué usar Lambda
- Empaquetar código Python en ZIP con `data "archive_file"`
- Crear funciones Lambda con variables de entorno
- Detectar cambios en el código automáticamente con `source_code_hash`
- Crear grupos de logs en CloudWatch
- Usar el bloque `lifecycle` para controlar el proceso de actualización
- Dar permisos de invocación externa con `aws_lambda_permission`
- Usar dos providers en el mismo archivo (`aws` + `archive`)

---

## Cómo ejecutar este módulo

```bash
docker-compose up -d
cd modulo-05-lambda
terraform init
terraform apply -auto-approve
terraform output
terraform destroy
```

---

## Concepto previo — ¿Qué es serverless?

Con un servidor tradicional pagas por el servidor **24/7**, lo uses o no. Con Lambda (serverless), pagas solo cuando **se ejecuta el código**.

```
Servidor tradicional:
  Servidor encendido 720h/mes → pagas 720h
  Se usa solo 5h/mes → igual pagas 720h

Lambda (serverless):
  Se ejecuta 5h/mes → pagas 5h
  El resto del tiempo: $0
```

Lambda ejecuta una función en respuesta a un evento (un mensaje SQS, una petición HTTP, un cambio en S3, etc.) y se "apaga" cuando termina.

---

## Código fuente de las funciones

Este módulo incluye dos archivos Python en `src/`:

```
modulo-05-lambda/
├── main.tf
└── src/
    ├── index.py        → Función "hello world"
    └── procesador.py   → Función procesadora de mensajes
```

Terraform necesita estos archivos en disco para empaquetarlos en ZIP.

---

## Bloque `terraform {}` con dos providers

```hcl
terraform {
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
```

Este módulo usa **dos providers**:

- `aws` → Para crear los recursos de AWS (Lambda, IAM, CloudWatch)
- `archive` → Para generar archivos ZIP desde el código fuente

El provider `archive` no interactúa con AWS. Solo procesa archivos localmente en tu máquina.

---

## Rol IAM para Lambda

```hcl
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
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
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
```

Lambda necesita un rol IAM para poder:
1. Escribir sus propios logs en CloudWatch
2. Acceder a otros recursos de AWS (S3 en este caso)

Sin este rol, Lambda no puede hacer nada fuera de ejecutar el código.

---

## Empaquetar código con `data "archive_file"`

```hcl
data "archive_file" "lambda_index" {
  type        = "zip"
  source_file = "${path.module}/src/index.py"
  output_path = "${path.module}/dist/index.zip"
}
```

**¿Qué hace?**

Crea un archivo ZIP del código Python que Lambda necesita. Terraform lo hace automáticamente antes de subir la función.

| Parámetro | Qué es |
|-----------|--------|
| `type = "zip"` | Formato del paquete |
| `source_file` | El archivo Python a empaquetar |
| `output_path` | Dónde guardar el ZIP resultante |
| `path.module` | Ruta absoluta al directorio del módulo actual |

**¿Por qué `source_code_hash`?**

```hcl
source_code_hash = data.archive_file.lambda_index.output_base64sha256
```

Terraform calcula un hash del ZIP. Si el código Python cambia, el hash cambia, y Terraform sabe que necesita volver a desplegar la función. Sin esto, Terraform no detectaría cambios en el código.

---

## Función Lambda — Hello World

```hcl
resource "aws_lambda_function" "hello" {
  function_name    = "${local.prefijo}-hello-world"
  filename         = data.archive_file.lambda_index.output_path
  source_code_hash = data.archive_file.lambda_index.output_base64sha256
  handler          = "index.handler"
  runtime          = "python3.11"
  role             = aws_iam_role.lambda.arn
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      ENTORNO     = var.entorno
      LOG_LEVEL   = "INFO"
      APP_VERSION = "1.0.0"
    }
  }

  tags = local.tags
}
```

**Parámetros explicados:**

| Parámetro | Qué hace |
|-----------|----------|
| `filename` | ZIP con el código. Terraform lo sube a Lambda |
| `source_code_hash` | Hash del ZIP para detectar cambios en el código |
| `handler = "index.handler"` | `archivo.función`. Lambda busca `def handler` en `index.py` |
| `runtime = "python3.11"` | Lenguaje de ejecución |
| `role` | ARN del rol IAM que la función asumirá |
| `timeout = 30` | Máximo 30 segundos de ejecución antes de cancelar |
| `memory_size = 128` | 128 MB de RAM (también afecta la velocidad de CPU) |

**Variables de entorno:**

```hcl
environment {
  variables = {
    ENTORNO     = var.entorno    # "dev"
    LOG_LEVEL   = "INFO"
    APP_VERSION = "1.0.0"
  }
}
```

El código Python puede leer estas variables con:

```python
import os
entorno = os.environ.get("ENTORNO", "desconocido")
```

Esto es fundamental para no hardcodear configuración en el código.

---

## Función Lambda — Procesador con `lifecycle`

```hcl
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

  lifecycle {
    create_before_destroy = true
  }

  tags = local.tags
}
```

### El bloque `lifecycle`

```hcl
lifecycle {
  create_before_destroy = true
}
```

Por defecto, cuando Terraform necesita reemplazar un recurso, lo **destruye primero y luego crea el nuevo**. Esto crea un tiempo de inactividad (downtime).

Con `create_before_destroy = true`, el orden se invierte:
1. Crea la nueva versión de la función
2. Espera a que esté lista
3. Destruye la versión anterior

Para Lambda, esto significa cero downtime al actualizar el código.

**Otros valores de `lifecycle`:**

```hcl
lifecycle {
  create_before_destroy = true   # Crea antes de destruir
  prevent_destroy       = true   # Previene que Terraform destruya este recurso
  ignore_changes        = [tags] # Ignora cambios en estos atributos
}
```

---

## CloudWatch Log Groups

```hcl
resource "aws_cloudwatch_log_group" "hello_logs" {
  name              = "/aws/lambda/${aws_lambda_function.hello.function_name}"
  retention_in_days = 7

  tags = local.tags
}
```

**¿Por qué crear el log group manualmente?**

Lambda crea automáticamente un log group al ejecutarse por primera vez. Sin embargo, si Terraform no lo gestiona:
- No puedes configurar la retención (por defecto guarda logs para siempre → caro)
- No puedes destruirlo con `terraform destroy`

Creándolo aquí con `retention_in_days = 7` los logs se eliminan automáticamente después de 7 días, ahorrando dinero.

**El nombre del log group sigue el patrón estándar de AWS:**

```
/aws/lambda/{nombre-de-la-funcion}
```

Usamos `${aws_lambda_function.hello.function_name}` para que coincida exactamente con el nombre de la función ya creada.

---

## Permiso de invocación externa

```hcl
resource "aws_lambda_permission" "allow_cloudwatch" {
  statement_id  = "AllowCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.hello.function_name
  principal     = "events.amazonaws.com"
}
```

**¿Para qué sirve?**

Por defecto, Lambda solo puede ser invocada por el propietario de la cuenta AWS. Si quieres que otro servicio (CloudWatch Events, API Gateway, S3, etc.) la invoque, necesitas agregar un permiso explícito.

Este `aws_lambda_permission` dice: "Permito que CloudWatch Events invoque esta función Lambda".

---

## Output especial — comando para invocar la Lambda

```hcl
output "comando_invocar_lambda" {
  description = "Comando para invocar la Lambda en LocalStack"
  value       = "aws --endpoint-url=http://localhost:4566 lambda invoke --function-name ${aws_lambda_function.hello.function_name} --payload '{\"key\": \"value\"}' /dev/stdout"
}
```

Este output genera el comando exacto de AWS CLI para probar la Lambda después del `apply`. Puedes copiarlo directamente:

```bash
terraform output comando_invocar_lambda
# Copia el comando que aparece y ejecútalo
```

---

## Flujo completo: del código al despliegue

```
src/index.py
     ↓
data "archive_file"       → genera  dist/index.zip
     ↓                              + calcula hash SHA256
aws_lambda_function.hello
  filename         = dist/index.zip
  source_code_hash = sha256(dist/index.zip)
  handler          = "index.handler"
  role             = aws_iam_role.lambda.arn
     ↓
Lambda en LocalStack lista para ejecutarse
```

Cada vez que modificas `src/index.py`:
1. `archive_file` regenera el ZIP → el hash cambia
2. Terraform detecta el cambio en `source_code_hash`
3. Terraform actualiza la función Lambda con el nuevo código

---

## Comandos para verificar en LocalStack

```bash
# Listar funciones Lambda
aws --endpoint-url=http://localhost:4566 lambda list-functions

# Invocar una función
aws --endpoint-url=http://localhost:4566 lambda invoke \
  --function-name lab-dev-hello-world \
  --payload '{"nombre": "Fernando"}' \
  /tmp/respuesta.json && cat /tmp/respuesta.json

# Ver variables de entorno de una función
aws --endpoint-url=http://localhost:4566 lambda get-function-configuration \
  --function-name lab-dev-hello-world

# Ver los log groups
aws --endpoint-url=http://localhost:4566 logs describe-log-groups
```

---

## Ejercicios propuestos

1. Modifica `src/index.py` (cambia cualquier cosa) y ejecuta `terraform plan`. ¿Terraform detecta el cambio en la función Lambda?

2. Agrega una nueva variable de entorno `MAX_RETRIES = "3"` a la función `hello` y aplica el cambio. ¿Es un cambio `~` (modify) o `-/+` (replace)?

3. Cambia el `timeout` a `120` y la `memory_size` a `512`. ¿Terraform destruye y recrea la función, o solo la modifica?

4. Cambia `create_before_destroy = false` en la función `procesador` y ejecuta `terraform plan`. ¿Cambia algo en el plan?

5. Invoca la Lambda con el comando del output y verifica que responde:
   ```bash
   aws --endpoint-url=http://localhost:4566 lambda invoke \
     --function-name lab-dev-hello-world \
     --payload '{"nombre": "EstudioTerraform"}' \
     /tmp/output.json && cat /tmp/output.json
   ```
