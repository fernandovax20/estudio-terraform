# ============================================================
# MÓDULO 15: CI/CD y GitOps PARA TERRAFORM
# ============================================================
# Aprenderás:
#   - Por qué NUNCA se ejecuta Terraform desde tu laptop en producción
#   - Modelo GitOps: Git como fuente de verdad
#   - State remoto con locking (evitar conflictos)
#   - Estructura de proyecto multi-entorno
#   - Cómo se ve un pipeline real (GitHub Actions, GitLab CI)
#   - Políticas de seguridad: plan obligatorio, aprobaciones
#   - Terraform Cloud / Atlantis como orquestadores
#   - Separación de responsabilidades: Terraform vs Auto-Scaler
#
# ╔══════════════════════════════════════════════════════════╗
# ║  CONCEPTO CLAVE: ¿QUÉ HACE TERRAFORM Y QUÉ NO?        ║
# ║                                                          ║
# ║  Terraform DEFINE:                                       ║
# ║    ✅ La infra base (VPCs, subnets, clusters)           ║
# ║    ✅ Las REGLAS de escalamiento (min, max, políticas)  ║
# ║    ✅ Los backups programados                            ║
# ║    ✅ Los presupuestos y alertas de costos               ║
# ║                                                          ║
# ║  Terraform NO HACE:                                      ║
# ║    ❌ Escalar/desescalar en tiempo real (eso lo hace     ║
# ║       AWS Auto Scaling, Kubernetes HPA, etc.)            ║
# ║    ❌ Desplegar código de aplicación (CI/CD de app)      ║
# ║    ❌ Responder a incidentes automáticamente              ║
# ║                                                          ║
# ║  Analogía: Terraform es el ARQUITECTO que diseña el      ║
# ║  edificio. AWS Auto Scaling es el SISTEMA ELÉCTRICO      ║
# ║  que enciende luces cuando detecta movimiento.            ║
# ╚══════════════════════════════════════════════════════════╝
#
# Comandos:
#   cd modulo-15-cicd-gitops
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

  # ──────────────────────────────────────────────────
  # BACKEND REMOTO (Comentado para LocalStack)
  # En producción, SIEMPRE usarías esto:
  # ──────────────────────────────────────────────────
  # backend "s3" {
  #   bucket         = "empresa-terraform-state"
  #   key            = "produccion/infraestructura.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-locks"  # ← LOCKING: evita que 2 personas apliquen a la vez
  #
  #   # IMPORTANTE: Las credenciales del backend vienen del pipeline,
  #   # no se hardcodean aquí. El pipeline inyecta:
  #   # - AWS_ACCESS_KEY_ID
  #   # - AWS_SECRET_ACCESS_KEY
  #   # mediante secretos de GitHub/GitLab
  # }
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
    iam      = "http://localhost:4566"
    sts      = "http://localhost:4566"
    ssm      = "http://localhost:4566"
  }
}

# ===========================================================
# PASO 1: BACKEND REMOTO (State + Locking)
# ===========================================================
# En un equipo real, el state se guarda en S3 con DynamoDB
# para locking. Esto PREVIENE que dos personas hagan
# "terraform apply" al mismo tiempo y corrompan el state.

# Bucket para el state file
resource "aws_s3_bucket" "terraform_state" {
  bucket = "empresa-terraform-state"

  tags = {
    Name      = "Terraform State"
    Gestion   = "terraform"
    Criticidad = "alta"
  }
}

resource "aws_s3_bucket_versioning" "state_versioning" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"  # ← Versioning para poder recuperar estados anteriores
  }
}

# Tabla DynamoDB para locking
resource "aws_dynamodb_table" "terraform_locks" {
  name         = "terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name    = "Terraform Lock Table"
    Gestion = "terraform"
  }
}

# ===========================================================
# PASO 2: ESTRUCTURA MULTI-ENTORNO
# ===========================================================
# En producción real, se separa por entornos usando:
# - Opción A: Directorios separados (más simple, más explícito)
# - Opción B: Workspaces de Terraform
# - Opción C: Terragrunt (wrapper que reduce duplicación)
#
# Ejemplo de Opción A (la más usada en empresas):
#
# infrastructure/
# ├── modules/                    # Módulos reutilizables
# │   ├── networking/
# │   ├── compute/
# │   └── database/
# ├── environments/
# │   ├── dev/
# │   │   ├── main.tf            # usa modules/ con valores de dev
# │   │   ├── variables.tf
# │   │   └── terraform.tfvars   # min_size=1, instance_type=t3.small
# │   ├── staging/
# │   │   ├── main.tf
# │   │   ├── variables.tf
# │   │   └── terraform.tfvars   # min_size=2, instance_type=t3.medium
# │   └── production/
# │       ├── main.tf
# │       ├── variables.tf
# │       └── terraform.tfvars   # min_size=3, instance_type=t3.large
# └── .github/
#     └── workflows/
#         └── terraform.yml       # Pipeline CI/CD

# Simulamos la config multi-entorno con SSM Parameters
locals {
  entornos = {
    dev = {
      min_size       = 1
      max_size       = 3
      instance_type  = "t3.small"
      multi_az       = false
      backup_enabled = false
    }
    staging = {
      min_size       = 2
      max_size       = 5
      instance_type  = "t3.medium"
      multi_az       = true
      backup_enabled = true
    }
    produccion = {
      min_size       = 3
      max_size       = 20
      instance_type  = "t3.large"
      multi_az       = true
      backup_enabled = true
    }
  }
}

resource "aws_ssm_parameter" "config_entorno" {
  for_each = local.entornos

  name  = "/infraestructura/${each.key}/config"
  type  = "String"
  value = jsonencode(each.value)

  tags = {
    entorno = each.key
    gestion = "terraform-cicd"
  }
}

# ===========================================================
# PASO 3: EL FLUJO GITOPS COMPLETO
# ===========================================================
# Este es el flujo que tu compañero describe como "orquestadores
# con pipelines". Así funciona:
#
# ┌─────────────────────────────────────────────────────────┐
# │                FLUJO GITOPS PARA TERRAFORM               │
# ├─────────────────────────────────────────────────────────┤
# │                                                          │
# │  1. Developer modifica main.tf en una BRANCH             │
# │     └── git checkout -b feature/agregar-cache            │
# │     └── (edita archivos .tf)                             │
# │     └── git push origin feature/agregar-cache            │
# │                                                          │
# │  2. Abre PULL REQUEST                                    │
# │     └── GitHub/GitLab ejecuta automáticamente:           │
# │         ├── terraform fmt -check  (formato)              │
# │         ├── terraform init        (inicializar)          │
# │         ├── terraform validate    (sintaxis)             │
# │         ├── terraform plan        (¿qué va a cambiar?)   │
# │         ├── tfsec / checkov       (seguridad)            │
# │         └── infracost             (¿cuánto costará?)     │
# │                                                          │
# │  3. REVISIÓN DEL EQUIPO                                  │
# │     └── El plan se publica como comentario en el PR      │
# │     └── Se requiere aprobación de al menos 1 persona     │
# │     └── Se verifica que no haya "destroy" inesperados    │
# │                                                          │
# │  4. MERGE a main                                         │
# │     └── El pipeline de main ejecuta:                     │
# │         └── terraform apply -auto-approve                │
# │     └── El state se actualiza en S3                      │
# │     └── Se notifica al equipo (Slack, Teams, etc)        │
# │                                                          │
# │  5. POST-APPLY                                           │
# │     └── Smoke tests (verificar que la infra funciona)    │
# │     └── Monitoring de costos                              │
# │     └── Rollback si algo falla (revert el commit)        │
# │                                                          │
# └─────────────────────────────────────────────────────────┘
#
# HERRAMIENTAS DE ORQUESTACIÓN:
#
# ┌────────────────────┬──────────────────────────────────────┐
# │ Herramienta        │ Descripción                          │
# ├────────────────────┼──────────────────────────────────────┤
# │ GitHub Actions     │ Pipeline nativo de GitHub. Gratuito. │
# │ GitLab CI          │ Pipeline nativo de GitLab.           │
# │ Atlantis           │ Bot de GitHub/GitLab para plan/apply │
# │                    │ Comenta el plan directo en el PR.    │
# │ Terraform Cloud    │ SaaS de HashiCorp. UI, locking,     │
# │                    │ políticas Sentinel, estimación costo │
# │ Spacelift          │ SaaS alternativo. Drift detection.   │
# │ Env0               │ SaaS con gestión de costos.          │
# │ Jenkins            │ Self-hosted, muy configurable.       │
# │ ArgoCD + TF        │ GitOps para Kubernetes + Terraform.  │
# └────────────────────┴──────────────────────────────────────┘

# ===========================================================
# PASO 4: SIMULACIÓN DE POLÍTICAS DE SEGURIDAD
# ===========================================================
# En producción, se implementan políticas que IMPIDEN cambios
# peligrosos sin aprobación.

# Simulamos roles con permisos separados para el pipeline
resource "aws_iam_role" "pipeline_plan" {
  name = "terraform-pipeline-plan"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "codebuild.amazonaws.com"
      }
    }]
  })

  tags = { pipeline = "plan-only" }
}

# Rol de PLAN: solo lectura (usado en PRs)
resource "aws_iam_role_policy" "pipeline_plan_policy" {
  name = "plan-only-policy"
  role = aws_iam_role.pipeline_plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadOnly"
        Effect = "Allow"
        Action = [
          "s3:Get*",
          "s3:List*",
          "dynamodb:GetItem",
          "dynamodb:Scan",
          "ec2:Describe*",
          "iam:Get*",
          "iam:List*"
        ]
        Resource = "*"
      },
      {
        Sid    = "StateBucketAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = "arn:aws:s3:::empresa-terraform-state/*"
      },
      {
        Sid    = "LockTable"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem"
        ]
        Resource = "arn:aws:dynamodb:*:*:table/terraform-locks"
      }
    ]
  })
}

# Rol de APPLY: permisos amplios (solo se usa en main branch)
resource "aws_iam_role" "pipeline_apply" {
  name = "terraform-pipeline-apply"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "codebuild.amazonaws.com"
      }
    }]
  })

  tags = { pipeline = "apply-full" }
}

resource "aws_iam_role_policy" "pipeline_apply_policy" {
  name = "full-apply-policy"
  role = aws_iam_role.pipeline_apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "FullAccess"
        Effect   = "Allow"
        Action   = "*"
        Resource = "*"
        # En producción real limitarías esto, pero el pipeline
        # de apply necesita crear/modificar/destruir recursos
      }
    ]
  })
}

# ===========================================================
# PASO 5: TERRAFORM vs AUTO-SCALER (La confusión de tu compa)
# ===========================================================
# Esto demuestra la SEPARACIÓN DE RESPONSABILIDADES.

# Terraform DEFINE las reglas de auto-scaling:
resource "aws_ssm_parameter" "scaling_rules" {
  name = "/infra/scaling/reglas-explicadas"
  type = "String"
  value = jsonencode({
    explicacion = "Terraform CREA estas reglas. AWS las EJECUTA en tiempo real."
    ejemplo = {
      terraform_define = {
        "aws_autoscaling_group" = {
          min_size         = 2
          max_size         = 20
          desired_capacity = 3
          nota             = "Terraform crea el ASG con estos límites"
        }
        "aws_autoscaling_policy" = {
          policy_type    = "TargetTrackingScaling"
          target_value   = 70.0
          metric         = "CPUUtilization"
          nota           = "Terraform define: escala cuando CPU > 70%"
        }
      }
      aws_ejecuta = {
        "las_3am"   = "CPU sube a 85% → AWS agrega 2 instancias automáticamente"
        "las_6am"   = "CPU baja a 30% → AWS quita 3 instancias automáticamente"
        "terraform" = "No interviene. Duerme. Su trabajo ya terminó."
      }
    }
    otros_orquestadores = {
      kubernetes = {
        terraform = "Crea el cluster EKS, node groups, y HPA rules"
        k8s_hpa   = "Escala pods automáticamente según métricas"
      }
      ecs = {
        terraform = "Crea el cluster ECS, service, y auto-scaling"
        aws       = "Escala tasks según la política definida"
      }
    }
  })
}

# ===========================================================
# PASO 6: EL CICLO DE VIDA REAL DE INFRAESTRUCTURA
# ===========================================================
resource "aws_ssm_parameter" "ciclo_de_vida" {
  name = "/infra/cicd/ciclo-completo"
  type = "String"
  value = jsonencode({
    "FASE_1_DISEÑO" = {
      quien   = "Equipo de infraestructura"
      que     = "Diseñar la arquitectura en Terraform"
      donde   = "Branch de feature"
      ejemplo = "Necesitamos un cluster Redis para cache"
    }
    "FASE_2_CODIGO" = {
      quien   = "Developer / SRE"
      que     = "Escribir el código Terraform"
      donde   = "Branch: feature/add-redis-cache"
      ejemplo = "Crear main.tf con ElastiCache + subnet group"
    }
    "FASE_3_PR_Y_REVIEW" = {
      quien              = "Todo el equipo"
      que                = "Revisar plan, costos, seguridad"
      herramientas       = ["terraform plan", "infracost", "tfsec", "checkov"]
      politica           = "Mínimo 2 aprobaciones para producción"
      se_revisa          = "¿Hay destroys? ¿Cuánto cuesta? ¿Es seguro?"
    }
    "FASE_4_APPLY" = {
      quien    = "Pipeline automático (NO un humano)"
      que      = "terraform apply en la cuenta correcta"
      cuando   = "Solo al hacer merge a main/master"
      rollback = "Revert del commit → pipeline aplica estado anterior"
    }
    "FASE_5_OPERACION" = {
      quien       = "AWS / Kubernetes / Cloud Provider"
      que         = "Ejecutar las reglas (scaling, backups, alertas)"
      terraform   = "No interviene hasta el próximo cambio"
      monitoreo   = "CloudWatch, Datadog, Grafana, PagerDuty"
    }
    "FASE_6_DIA_2" = {
      quien       = "SRE / Platform team"
      que         = "Ajustar, optimizar, parchear"
      ejemplo     = "Subir max_size de 10 a 20 → nuevo PR → nuevo ciclo"
      drift       = "Detectar si alguien cambió algo fuera de Terraform"
    }
  })
}

# ===========================================================
# OUTPUTS
# ===========================================================
output "backend_state" {
  value = {
    bucket     = aws_s3_bucket.terraform_state.id
    lock_table = aws_dynamodb_table.terraform_locks.id
    nota       = "En producción, TODOS los entornos guardan su state aquí"
  }
}

output "roles_pipeline" {
  value = {
    plan_role  = aws_iam_role.pipeline_plan.arn
    apply_role = aws_iam_role.pipeline_apply.arn
    nota       = "PR usa plan_role (read-only). Merge usa apply_role (full)."
  }
}

output "entornos_config" {
  value = { for k, v in local.entornos : k => v }
}

output "diagrama_gitops" {
  value = <<-EOF

    ════════════════════════════════════════════════════════════
               FLUJO GITOPS PARA TERRAFORM
    ════════════════════════════════════════════════════════════

    Developer         GitHub/GitLab         AWS Account
    ─────────         ─────────────         ───────────
        │                   │                     │
        │  git push         │                     │
        ├──────────────────>│                     │
        │                   │                     │
        │  Abre PR          │                     │
        ├──────────────────>│                     │
        │                   │── terraform fmt     │
        │                   │── terraform init    │
        │                   │── terraform plan ───┤ (read-only)
        │                   │── tfsec (seguridad) │
        │                   │── infracost ($$$)   │
        │                   │                     │
        │  Plan como        │                     │
        │  comentario en PR │                     │
        │<──────────────────│                     │
        │                   │                     │
        │  Equipo aprueba   │                     │
        ├──────────────────>│                     │
        │                   │                     │
        │  Merge a main     │                     │
        ├──────────────────>│                     │
        │                   │── terraform apply ──┤ (full access)
        │                   │                     │── Crea recursos
        │                   │                     │── Configura ASG
        │                   │                     │── Define reglas
        │                   │                     │
        │                   │                     │  ┌──────────────┐
        │                   │                     │  │ Auto Scaling │
        │                   │                     │  │ (AWS se      │
        │                   │                     │  │  encarga     │
        │                   │                     │  │  24/7)       │
        │                   │                     │  └──────────────┘
        │                   │                     │
        │  Notificación     │                     │
        │  "Deploy OK ✓"    │                     │
        │<──────────────────│                     │
        │                   │                     │

    ════════════════════════════════════════════════════════════
      TU COMPA DICE: "Terraform es solo una maqueta"
      REALIDAD: Terraform es el PLANO del edificio.
                El pipeline CI/CD es la CONSTRUCTORA.
                AWS Auto Scaling es el SISTEMA AUTOMÁTICO.
    ════════════════════════════════════════════════════════════

  EOF
}

# --------------------------------------------------
# EJERCICIOS PROPUESTOS:
# --------------------------------------------------
# 1. Crea un workspace "staging" (terraform workspace new staging)
#    y observa cómo cambia el state file.
#
# 2. Modifica un recurso y ejecuta "terraform plan".
#    Imagina que eres el reviewer del PR: ¿aprobarías?
#
# 3. Simula un "rollback": destruye un recurso y luego
#    usa "terraform apply" para recrearlo.
#
# 4. Investiga Atlantis (runatlantis.io) — es un bot que
#    comenta directamente en tu PR con el plan.
#
# 5. Mira los archivos de ejemplo en la carpeta pipelines/:
#    - github-actions.yml
#    - gitlab-ci.yml
#    ¿Cuál usarías en tu empresa?
#
# 6. ¿Qué pasa si alguien cambia un recurso desde la consola
#    de AWS sin usar Terraform? Se llama "drift".
#    Investiga: terraform plan -detailed-exitcode
