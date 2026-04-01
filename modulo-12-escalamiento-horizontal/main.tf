# ============================================================
# MÓDULO 12: ESCALAMIENTO HORIZONTAL - Auto Scaling Groups
# ============================================================
# Aprenderás:
#   - Launch Templates (plantillas de lanzamiento)
#   - Auto Scaling Groups (ASG) - agregar/quitar instancias
#   - Scaling Policies (políticas de escalado automático)
#   - Target Tracking (escalar según métricas)
#   - Step Scaling (escalar por pasos)
#   - Scheduled Scaling (escalar por horario)
#   - Integración ALB + ASG
#   - CloudWatch Alarms para escalar
#   - Cooldown periods
#
# Concepto clave: ESCALAMIENTO HORIZONTAL (Scale Out/In)
#   = Agregar o quitar MÁQUINAS según la demanda.
#   En lugar de hacer una máquina más grande,
#   añades más máquinas idénticas.
#
# Comandos:
#   cd modulo-12-escalamiento-horizontal
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
    ec2            = "http://localhost:4566"
    elbv2          = "http://localhost:4566"
    autoscaling    = "http://localhost:4566"
    cloudwatch     = "http://localhost:4566"
    sts            = "http://localhost:4566"
    sns            = "http://localhost:4566"
  }
}

variable "entorno" {
  type    = string
  default = "dev"
}

variable "min_instancias" {
  description = "Mínimo de instancias en el ASG"
  type        = number
  default     = 2
}

variable "max_instancias" {
  description = "Máximo de instancias en el ASG"
  type        = number
  default     = 10
}

variable "instancias_deseadas" {
  description = "Número deseado de instancias"
  type        = number
  default     = 3
}

locals {
  prefijo = "lab-${var.entorno}"
  tags = {
    proyecto = "estudio-terraform"
    modulo   = "12-escalamiento-horizontal"
    entorno  = var.entorno
  }
}

# ===========================================================
# RED BASE
# ===========================================================

resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = merge(local.tags, { Name = "${local.prefijo}-vpc-asg" })
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${local.prefijo}-igw" })
}

resource "aws_subnet" "publica" {
  count                   = 3
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet("10.20.0.0/16", 8, count.index)
  availability_zone       = "us-east-1${["a", "b", "c"][count.index]}"
  map_public_ip_on_launch = true
  tags = merge(local.tags, {
    Name = "${local.prefijo}-pub-${count.index}"
  })
}

resource "aws_route_table" "publica" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = merge(local.tags, { Name = "${local.prefijo}-rt-pub" })
}

resource "aws_route_table_association" "publica" {
  count          = 3
  subnet_id      = aws_subnet.publica[count.index].id
  route_table_id = aws_route_table.publica.id
}

resource "aws_security_group" "alb" {
  name   = "${local.prefijo}-sg-alb-asg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.prefijo}-sg-alb-asg" })
}

resource "aws_security_group" "instancias" {
  name   = "${local.prefijo}-sg-inst-asg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.prefijo}-sg-inst-asg" })
}

# ===========================================================
# ALB para el Auto Scaling Group
# ===========================================================

resource "aws_lb" "asg" {
  name               = "${local.prefijo}-alb-asg"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.publica[*].id

  tags = merge(local.tags, { Name = "${local.prefijo}-alb-asg" })
}

resource "aws_lb_target_group" "asg" {
  name        = "${local.prefijo}-tg-asg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 15
    matcher             = "200"
  }

  # Desregistrar instancias gradualmente al escalar hacia abajo
  deregistration_delay = 30

  tags = merge(local.tags, { Name = "${local.prefijo}-tg-asg" })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.asg.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.asg.arn
  }

  tags = local.tags
}

# ===========================================================
# LAUNCH TEMPLATE (Plantilla para nuevas instancias)
# ===========================================================
# El Launch Template define CÓMO se crean las instancias.
# El ASG decide CUÁNTAS y CUÁNDO crear/destruir.

resource "aws_launch_template" "app" {
  name          = "${local.prefijo}-lt-app"
  image_id      = "ami-0123456789abcdef0"
  instance_type = "t2.micro"               # Todas iguales (horizontal)

  vpc_security_group_ids = [aws_security_group.instancias.id]

  # Script de inicio para cada instancia nueva
  user_data = base64encode(<<-SCRIPT
    #!/bin/bash
    INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    echo "Instancia $INSTANCE_ID iniciada por ASG" > /var/log/asg-startup.log
    echo "Fecha: $(date)" >> /var/log/asg-startup.log

    # Simulación de un servidor web
    cat > /var/www/html/health <<EOF2
    {"status": "healthy", "instance": "$INSTANCE_ID"}
    EOF2
  SCRIPT
  )

  # Metadatos de tags para instancias creadas por el ASG
  tag_specifications {
    resource_type = "instance"
    tags = merge(local.tags, {
      Name        = "${local.prefijo}-asg-instancia"
      creado_por  = "auto-scaling-group"
      escala      = "horizontal"
    })
  }

  # Versionado del template
  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.tags, { Name = "${local.prefijo}-lt-app" })
}

# ===========================================================
# AUTO SCALING GROUP
# ===========================================================
# El ASG gestiona automáticamente el número de instancias.
# Escala horizontalmente: agrega instancias (scale out)
# o las quita (scale in) según las políticas.

resource "aws_autoscaling_group" "app" {
  name                = "${local.prefijo}-asg-app"
  min_size            = var.min_instancias       # Mínimo 2 instancias (alta disponibilidad)
  max_size            = var.max_instancias       # Máximo 10 instancias
  desired_capacity    = var.instancias_deseadas  # Empezar con 3

  # Subnets donde lanzar instancias (multi-AZ)
  vpc_zone_identifier = aws_subnet.publica[*].id

  # Conectar con el ALB
  target_group_arns = [aws_lb_target_group.asg.arn]

  # Health check: el ASG reemplaza instancias no saludables
  health_check_type         = "ELB"   # Usar el health check del ALB
  health_check_grace_period = 120     # Esperar 2 min después de lanzar

  # Qué hacer al reemplazar instancias
  force_delete              = false
  wait_for_capacity_timeout = "0"

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  # Tags que se aplican a las instancias creadas
  tag {
    key                 = "proyecto"
    value               = "estudio-terraform"
    propagate_at_launch = true
  }

  tag {
    key                 = "gestionado_por"
    value               = "asg"
    propagate_at_launch = true
  }
}

# ===========================================================
# SCALING POLICIES (Políticas de escalado)
# ===========================================================

# --------------------------------------------------
# 1. TARGET TRACKING: Escalar para mantener un objetivo
# --------------------------------------------------
# "Mantener el uso de CPU promedio en 60%"
# Si sube de 60% → agrega instancias (scale out)
# Si baja de 60% → quita instancias (scale in)

resource "aws_autoscaling_policy" "cpu_target" {
  name                   = "${local.prefijo}-cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value     = 60.0   # Mantener CPU al 60%
    disable_scale_in = false  # Permitir reducir instancias
  }
}

# Target tracking por requests por instancia
resource "aws_autoscaling_policy" "requests_target" {
  name                   = "${local.prefijo}-requests-target"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.asg.arn_suffix}/${aws_lb_target_group.asg.arn_suffix}"
    }
    target_value = 1000  # 1000 requests por instancia
  }
}

# --------------------------------------------------
# 2. STEP SCALING: Escalar por pasos según severidad
# --------------------------------------------------
# Más flexible: distintos incrementos según cuánto se desvíe

resource "aws_autoscaling_policy" "scale_out_steps" {
  name                   = "${local.prefijo}-scale-out-steps"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "StepScaling"
  adjustment_type        = "ChangeInCapacity"

  # Esperar 60s entre ajustes
  estimated_instance_warmup = 60

  step_adjustment {
    # CPU 70-80%: agregar 1 instancia
    metric_interval_lower_bound = 0
    metric_interval_upper_bound = 10
    scaling_adjustment          = 1
  }

  step_adjustment {
    # CPU 80-90%: agregar 2 instancias
    metric_interval_lower_bound = 10
    metric_interval_upper_bound = 20
    scaling_adjustment          = 2
  }

  step_adjustment {
    # CPU > 90%: agregar 4 instancias (emergencia)
    metric_interval_lower_bound = 20
    scaling_adjustment          = 4
  }
}

resource "aws_autoscaling_policy" "scale_in_steps" {
  name                   = "${local.prefijo}-scale-in-steps"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "StepScaling"
  adjustment_type        = "ChangeInCapacity"

  step_adjustment {
    # CPU < 30%: quitar 1 instancia
    metric_interval_upper_bound = 0
    scaling_adjustment          = -1
  }
}

# --------------------------------------------------
# 3. SCHEDULED SCALING: Escalar por horario
# --------------------------------------------------
# Útil cuando conoces los patrones de tráfico.

# Lunes a viernes 9am: escalar a 5 instancias (horario laboral)
resource "aws_autoscaling_schedule" "horario_pico" {
  scheduled_action_name  = "escalar-horario-pico"
  autoscaling_group_name = aws_autoscaling_group.app.name
  min_size               = 3
  max_size               = 10
  desired_capacity       = 5
  recurrence             = "0 9 * * 1-5"  # Cron: 9am Lun-Vie
  time_zone              = "America/Mexico_City"
}

# Lunes a viernes 7pm: reducir a 2 instancias (noche)
resource "aws_autoscaling_schedule" "horario_bajo" {
  scheduled_action_name  = "reducir-horario-bajo"
  autoscaling_group_name = aws_autoscaling_group.app.name
  min_size               = 1
  max_size               = 5
  desired_capacity       = 2
  recurrence             = "0 19 * * 1-5"  # Cron: 7pm Lun-Vie
  time_zone              = "America/Mexico_City"
}

# Fines de semana: mínimo
resource "aws_autoscaling_schedule" "fin_de_semana" {
  scheduled_action_name  = "minimo-fin-de-semana"
  autoscaling_group_name = aws_autoscaling_group.app.name
  min_size               = 1
  max_size               = 3
  desired_capacity       = 1
  recurrence             = "0 0 * * 6"  # Sábado medianoche
  time_zone              = "America/Mexico_City"
}

# --------------------------------------------------
# CLOUDWATCH ALARMS (Alarmas para triggear scaling)
# --------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "cpu_alta" {
  alarm_name          = "${local.prefijo}-cpu-alta"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2                    # 2 periodos consecutivos
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60                   # 60 segundos
  statistic           = "Average"
  threshold           = 70                   # Umbral: 70% CPU
  alarm_description   = "CPU promedio > 70% por 2 minutos"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_out_steps.arn]

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "cpu_baja" {
  alarm_name          = "${local.prefijo}-cpu-baja"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 30

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_in_steps.arn]

  tags = local.tags
}

# --------------------------------------------------
# SNS TOPIC para notificaciones de ASG
# --------------------------------------------------
resource "aws_sns_topic" "asg_notificaciones" {
  name = "${local.prefijo}-asg-notificaciones"
  tags = local.tags
}

resource "aws_autoscaling_notification" "asg_eventos" {
  group_names = [aws_autoscaling_group.app.name]
  topic_arn   = aws_sns_topic.asg_notificaciones.arn

  notifications = [
    "autoscaling:EC2_INSTANCE_LAUNCH",           # Nueva instancia creada
    "autoscaling:EC2_INSTANCE_TERMINATE",         # Instancia eliminada
    "autoscaling:EC2_INSTANCE_LAUNCH_ERROR",      # Error al crear
    "autoscaling:EC2_INSTANCE_TERMINATE_ERROR",   # Error al eliminar
  ]
}

# ===========================================================
# OUTPUTS
# ===========================================================
output "alb_dns" {
  value = aws_lb.asg.dns_name
}

output "asg_nombre" {
  value = aws_autoscaling_group.app.name
}

output "asg_capacidad" {
  value = {
    minimo  = aws_autoscaling_group.app.min_size
    maximo  = aws_autoscaling_group.app.max_size
    deseado = aws_autoscaling_group.app.desired_capacity
  }
}

output "politicas_escalado" {
  value = {
    cpu_target_tracking = aws_autoscaling_policy.cpu_target.name
    scale_out_steps     = aws_autoscaling_policy.scale_out_steps.name
    scale_in_steps      = aws_autoscaling_policy.scale_in_steps.name
  }
}

output "horarios_programados" {
  value = [
    "Pico: Lun-Vie 9am → 5 instancias",
    "Bajo: Lun-Vie 7pm → 2 instancias",
    "Weekend: Sáb 12am → 1 instancia",
  ]
}

output "diagrama_asg" {
  value = <<-EOF

    ESCALAMIENTO HORIZONTAL (Scale Out / Scale In)

    ┌─────────────────────────────────────────────────────┐
    │                 AUTO SCALING GROUP                   │
    │                                                     │
    │  Mínimo: ${var.min_instancias}    Deseado: ${var.instancias_deseadas}    Máximo: ${var.max_instancias}              │
    │                                                     │
    │  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐     │
    │  │ EC2  │ │ EC2  │ │ EC2  │ │ EC2  │ │ EC2  │     │
    │  │micro │ │micro │ │micro │ │micro │ │micro │     │
    │  └──────┘ └──────┘ └──────┘ └──────┘ └──────┘     │
    │     ▲        ▲        ▲        ▲        ▲          │
    │     │        │        │        │        │          │
    │  ┌──┴────────┴────────┴────────┴────────┴──┐       │
    │  │         ALB (distribuye tráfico)         │       │
    │  └─────────────────────────────────────────┘       │
    └─────────────────────────────────────────────────────┘
                           │
                  ┌────────┴────────┐
                  │ Scaling Policies │
                  ├─────────────────┤
                  │ CPU > 70% → +1  │  Scale Out ──→
                  │ CPU > 80% → +2  │  Scale Out ──→→
                  │ CPU > 90% → +4  │  Scale Out ──→→→→
                  │ CPU < 30% → -1  │  ←── Scale In
                  └─────────────────┘

    Horizontal: todas las instancias son t2.micro (iguales)
    Se agregan/quitan instancias, no se cambia el tamaño.

  EOF
}

# --------------------------------------------------
# EJERCICIOS PROPUESTOS:
# --------------------------------------------------
# 1. Cambia min_instancias a 1 y max a 20. Observa el plan.
#
# 2. Agrega una política de target tracking para mantener
#    la latencia promedio del ALB por debajo de 500ms.
#
# 3. Crea un segundo ASG "batch" para trabajos pesados
#    con instancias t2.large y máximo 5.
#
# 4. Modifica el Launch Template para cambiar el user_data.
#    ¿El ASG reemplaza las instancias existentes?
#
# 5. Agrega un horario para "Black Friday" con máximo 50 instancias.
#
# 6. Escala manualmente:
#    aws --endpoint-url=http://localhost:4566 autoscaling \
#      set-desired-capacity --auto-scaling-group-name lab-dev-asg-app \
#      --desired-capacity 6
#
# 7. Compara con el Módulo 11 (vertical):
#    Vertical: cambias t2.micro → t2.large (máquina más grande)
#    Horizontal: agregas más t2.micro (más máquinas iguales)
