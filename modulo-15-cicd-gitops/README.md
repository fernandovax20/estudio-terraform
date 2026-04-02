# Módulo 15 — CI/CD y GitOps

## ¿Qué vas a aprender?

- Por qué no ejecutar Terraform manualmente en producción
- El modelo GitOps: Git como fuente de verdad
- Cómo estructurar backends para múltiples entornos
- Pipeline de CI/CD para Terraform con GitHub Actions y GitLab CI
- `default_tags` en el provider: tagging automático de todos los recursos
- Estructura de directorios para proyectos Terraform multi-entorno
- Secretos y variables en pipelines

---

## Cómo ejecutar este módulo

```bash
docker-compose up -d
cd modulo-15-cicd-gitops
terraform init
terraform apply -auto-approve
terraform output
terraform destroy
```

---

## El problema con Terraform manual

En entornos de desarrollo pequeños, ejecutar `terraform apply` desde tu terminal está bien. En producción, esto genera problemas:

```
❌ PROBLEMAS CON TERRAFORM MANUAL:

1. ¿Quién aplicó los cambios?
   - No hay registro de "el martes a las 3pm, Juan aplicó este cambio"

2. ¿Qué cambios se aplicaron exactamente?
   - El `terraform.tfstate` puede estar desincronizado

3. ¿Se revisó el plan antes de aplicar?
   - Cualquiera puede hacer terraform apply sin aprobación

4. ¿Está aprobado el cambio?
   - No hay proceso de revisión

5. ¿Qué versión de Terraform se usó?
   - En tu máquina tienes 1.5, tu compañero tiene 1.3
```

GitOps resuelve todos estos problemas.

---

## El modelo GitOps

**GitOps** = Git es la única fuente de verdad. Ningún cambio llega a producción sin pasar por Git.

```
FLUJO GITOPS:

1. Desarrollador crea una rama (feature/nueva-vpc)
2. Hace commit de los cambios en Terraform
3. Abre un Pull Request / Merge Request
4. El pipeline ejecuta automáticamente:
   - terraform fmt -check    (¿está formateado?)
   - terraform validate      (¿es válido?)
   - terraform plan          (¿qué va a cambiar?)
5. El plan se publica como comentario en el PR
6. Un revisor aprueba el PR tras revisar el plan
7. Se hace merge a main
8. El pipeline ejecuta terraform apply automáticamente
```

```
Ventajas:
✅ Todo cambio está en el historial de Git
✅ El plan siempre se revisa antes de aplicar
✅ Aprobación requerida (code review)
✅ Versión de Terraform fijada en el pipeline
✅ Estado del deployment en el repositorio
```

---

## Backend multi-entorno

Para múltiples entornos, cada entorno tiene su propio state:

```hcl
terraform {
  backend "s3" {
    bucket         = "terraform-state-empresa"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"

    # Cada entorno tiene su propia key (path) en el bucket
    # dev:        "modulo-15/dev/terraform.tfstate"
    # staging:    "modulo-15/staging/terraform.tfstate"
    # produccion: "modulo-15/produccion/terraform.tfstate"
    key = "modulo-15/${var.entorno}/terraform.tfstate"
  }
}
```

Esta separación garantiza que un `terraform apply` en `dev` nunca toca los recursos de `produccion`.

---

## `default_tags` — Tagging automático

El bloque `default_tags` en el provider aplica automáticamente las tags a **todos** los recursos que se creen:

```hcl
provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Proyecto    = "mi-aplicacion"
      Entorno     = var.entorno
      GestionadoPor = "terraform"
      Repositorio = "github.com/empresa/infraestructura"
      # Estas tags se aplican a CADA recurso creado
    }
  }
}
```

Sin `default_tags`, tendrías que añadir el bloque `tags` a cada recurso individualmente. Con `default_tags`, se añaden automáticamente y se combinan con las tags específicas de cada recurso.

---

## Configuración por entorno

```hcl
locals {
  config_entornos = {
    dev = {
      instancias          = 1
      instance_type       = "t2.micro"
      retencion_logs_dias = 7
      alertas_activas     = false
    }
    staging = {
      instancias          = 2
      instance_type       = "t2.small"
      retencion_logs_dias = 14
      alertas_activas     = true
    }
    produccion = {
      instancias          = 3
      instance_type       = "t2.medium"
      retencion_logs_dias = 90
      alertas_activas     = true
    }
  }

  config = local.config_entornos[var.entorno]
}

resource "aws_sqs_queue" "app" {
  name                      = "app-${var.entorno}"
  message_retention_seconds = local.config.retencion_logs_dias * 86400
}
```

Con este patrón, el mismo código funciona para los 3 entornos. El entorno se pasa como variable (`-var="entorno=produccion"`).

---

## Pipeline: GitHub Actions

```yaml
# .github/workflows/terraform.yml
name: Terraform CI/CD

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v2
        with:
          terraform_version: "1.6.0"   # Versión fija

      - name: Terraform Format
        run: terraform fmt -check -recursive
        # Falla si el código no está correctamente formateado

      - name: Terraform Init
        run: terraform init -backend-config="key=${{ vars.ENTORNO }}/terraform.tfstate"
        env:
          AWS_ACCESS_KEY_ID:     ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}

      - name: Terraform Validate
        run: terraform validate
        # Verifica que el código es sintácticamente correcto

      - name: Terraform Plan
        id: plan
        run: terraform plan -no-color -out=tfplan
        env:
          TF_VAR_entorno: ${{ vars.ENTORNO }}

      - name: Publicar plan como comentario
        uses: actions/github-script@v6
        with:
          script: |
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              body: `**Terraform Plan:**\n\`\`\`\n${{ steps.plan.outputs.stdout }}\n\`\`\``
            })

  apply:
    runs-on: ubuntu-latest
    needs: validate
    if: github.ref == 'refs/heads/main'   # Solo en la rama main (post-merge)
    environment: production               # Requiere aprobación manual en GitHub
    steps:
      - name: Terraform Apply
        run: terraform apply tfplan
```

---

## Pipeline: GitLab CI

```yaml
# .gitlab-ci.yml
stages:
  - validate
  - plan
  - apply

variables:
  TF_VERSION: "1.6.0"

.terraform_base: &terraform_base
  image: hashicorp/terraform:$TF_VERSION
  before_script:
    - terraform init

validate:
  <<: *terraform_base
  stage: validate
  script:
    - terraform fmt -check
    - terraform validate

plan:
  <<: *terraform_base
  stage: plan
  script:
    - terraform plan -out=tfplan
  artifacts:
    paths: [tfplan]   # Guardar el plan para el step apply

apply:
  <<: *terraform_base
  stage: apply
  script:
    - terraform apply tfplan
  when: manual         # Requiere clic manual para aplicar
  only: [main]
  dependencies: [plan]
```

---

## Estructura de directorios recomendada

```
infraestructura/
├── modules/                   # Módulos reutilizables
│   ├── vpc/
│   ├── eks/
│   └── rds/
├── environments/
│   ├── dev/
│   │   ├── main.tf            # Llama a los módulos con config de dev
│   │   ├── variables.tf
│   │   └── terraform.tfvars   # Valores para dev
│   ├── staging/
│   │   ├── main.tf
│   │   └── terraform.tfvars
│   └── produccion/
│       ├── main.tf
│       └── terraform.tfvars
└── .github/
    └── workflows/
        └── terraform.yml
```

Con esta estructura, los pipelines de cada entorno son independientes. Puedes aprobar cambios en dev sin afectar staging.

---

## Ejercicios propuestos

1. Revisa el archivo `pipelines/github-actions.yml` y `pipelines/gitlab-ci.yml` en este módulo. ¿En qué se diferencian?

2. Modifica la configuración de entornos (`local.config_entornos`) para agregar un entorno `qa` con `instancias = 2` y `instance_type = "t2.small"`.

3. ¿Qué pasa si ejecutas `terraform apply -var="entorno=produccion"` en tu máquina local apuntando al backend S3 de producción? ¿Qué mecanismo te protegería de hacerlo accidentalmente?

4. Agrega `TF_VAR_entorno` como variable de entorno en el pipeline y verifica que se pasa correctamente a Terraform.

5. ¿Por qué `terraform plan -out=tfplan` y luego `terraform apply tfplan` (en lugar de solo `terraform apply`) es más seguro en un pipeline?
