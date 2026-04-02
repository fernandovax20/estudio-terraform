# Módulo 12 — Escalamiento Horizontal

## ¿Qué vas a aprender?

- Qué es el escalamiento horizontal y por qué es preferible
- Launch Templates: la "receta" para crear instancias
- Auto Scaling Groups: gestionar un grupo de instancias automáticamente
- Scaling policies: cuándo y cómo escalar
  - Target Tracking: mantener una métrica en un valor objetivo
  - Step Scaling: escalar en escalones según el nivel de alarma
  - Scheduled Scaling: escalar a horas específicas
- CloudWatch Alarms: detectar cuándo hay que escalar
- El concepto de `desired_capacity`, `min_size`, `max_size`

---

## Cómo ejecutar este módulo

```bash
docker-compose up -d
cd modulo-12-escalamiento-horizontal
terraform init
terraform apply -auto-approve
terraform output
terraform destroy
```

---

## ¿Por qué el escalamiento horizontal es mejor?

El escalamiento vertical tiene un límite físico: no hay instancias infinitamente grandes. Además, escalar verticalmente generalmente requiere reiniciar la instancia (downtime).

El escalamiento horizontal no tiene límite práctico: si necesitas más capacidad, añades más instancias iguales. Cuando la carga baja, las eliminas.

```
ESCALAMIENTO VERTICAL:
  ☐ (pequeño) → ☐ (grande)    Cambias el tamaño

ESCALAMIENTO HORIZONTAL:
  ☐ → ☐☐ → ☐☐☐☐              Añades más del mismo tamaño
  ☐☐☐☐ → ☐☐ → ☐             Eliminas cuando baja la carga
```

---

## Recurso 1: Launch Template — la "receta"

Un Launch Template define cómo debe ser cada instancia que se cree:

```hcl
resource "aws_launch_template" "app" {
  name_prefix   = "lt-app-"
  description   = "Template para instancias de la aplicación"
  image_id      = var.ami_id
  instance_type = var.instance_type   # e.g. "t2.micro"

  # Script de inicialización
  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    yum install -y httpd
    systemctl start httpd
    echo "Hola desde $(hostname)" > /var/www/html/index.html
    echo "OK" > /var/www/html/health
  EOF
  )

  # Reglas de red
  vpc_security_group_ids = [aws_security_group.instancias.id]

  monitoring {
    enabled = true   # Habilita CloudWatch detailed monitoring
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.tags, { Name = "app-${var.entorno}" })
  }

  lifecycle {
    create_before_destroy = true   # Crea la nueva versión antes de destruir la vieja
  }
}
```

El `user_data` es el script que se ejecuta al arrancar la instancia. Aquí instalar dependencias, configurar el servidor, etc.

`base64encode()` es necesario porque EC2 espera el user_data en base64, no en texto plano.

---

## Recurso 2: Auto Scaling Group

El ASG gestiona un conjunto de instancias y las mantiene en el número deseado:

```hcl
resource "aws_autoscaling_group" "app" {
  name_prefix         = "asg-app-"
  desired_capacity    = 3    # Cuántas quieres normalmente
  min_size            = 2    # Mínimo absoluto (nunca baja de aquí)
  max_size            = 10   # Máximo absoluto (nunca sube de aquí)

  # En qué subnets crear las instancias
  vpc_zone_identifier = var.subnet_ids

  # Qué template usar para crear instancias
  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"   # Usa siempre la última versión del template
  }

  # Qué target group de un ALB usa este ASG
  target_group_arns = [aws_lb_target_group.app.arn]

  # Cómo verificar si una instancia está sana
  health_check_type         = "ELB"    # Usa el health check del ALB
  health_check_grace_period = 300      # Espera 5 min al arrancar antes de revisar

  # Distribuir instancias uniformemente entre AZs
  availability_zones = var.availability_zones

  # Las instancias se llaman "app-dev-001", "app-dev-002"...
  tag {
    key                 = "Name"
    value               = "app-${var.entorno}"
    propagate_at_launch = true   # Aplica la tag también a las instancias
  }
}
```

**Los tres valores clave:**

| Parámetro | Significado | Ejemplo |
|-----------|------------|---------|
| `min_size` | Nunca menos de este número | `2` (alta disponibilidad mínima) |
| `max_size` | Nunca más de este número | `10` (límite de costo) |
| `desired_capacity` | Cuántas quieres ahora | `3` (normal) |

Cuando las políticas de scaling actúan, cambian el `desired_capacity` dentro de los límites `min_size` y `max_size`.

---

## Recurso 3: Target Tracking Policy

La política más sencilla: "mantén la CPU al 70%".

```hcl
resource "aws_autoscaling_policy" "cpu_target" {
  name                   = "cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 70.0   # Mantener CPU al 70%
  }
}
```

**¿Cómo funciona?**

```
CPU > 70% → ASG añade instancias hasta que CPU ≤ 70%
CPU < 70% → ASG elimina instancias hasta que CPU ≥ 70%
```

AWS calcula automáticamente cuántas instancias añadir o quitar. No necesitas configurar alarmas.

---

## Recurso 4: Step Scaling Policy (escalamiento por pasos)

Más control: escalar diferente cantidad según el nivel de alarma:

```hcl
resource "aws_autoscaling_policy" "scale_out" {
  name                   = "scale-out-steps"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "StepScaling"
  adjustment_type        = "ChangeInCapacity"   # Añadir/quitar N instancias

  step_adjustment {
    metric_interval_lower_bound = 0    # CPU entre 80 y 90 → añade 2
    metric_interval_upper_bound = 10
    scaling_adjustment          = 2
  }

  step_adjustment {
    metric_interval_lower_bound = 10   # CPU > 90 → añade 4
    scaling_adjustment          = 4
  }
}
```

Necesita una alarma de CloudWatch que dispare la política:

```hcl
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "cpu-utilization-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2          # 2 periodos seguidos
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60         # Cada 60 segundos
  statistic           = "Average"
  threshold           = 80         # Si CPU >= 80%

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_out.arn]
}
```

**La alarma activa la política:**

```
CPU >= 80% por 2 periodos → Alarma → Scale Out Policy
  - Si CPU entre 80-90%: añade 2 instancias
  - Si CPU > 90%: añade 4 instancias
```

---

## Recurso 5: Scheduled Scaling — escalar a horas fijas

Si sabes que los lunes a las 9:00 siempre hay pico de tráfico:

```hcl
resource "aws_autoscaling_schedule" "business_hours" {
  scheduled_action_name  = "business-hours-scale-out"
  autoscaling_group_name = aws_autoscaling_group.app.name
  min_size               = 5
  max_size               = 15
  desired_capacity       = 8
  recurrence             = "0 9 * * MON-FRI"   # Formato cron
}

resource "aws_autoscaling_schedule" "night_hours" {
  scheduled_action_name  = "night-hours-scale-in"
  autoscaling_group_name = aws_autoscaling_group.app.name
  min_size               = 1
  max_size               = 5
  desired_capacity       = 2
  recurrence             = "0 22 * * *"   # Cada día a las 22:00
}
```

**Formato cron:** `minuto hora día-mes mes día-semana`

En horario laboral: 8 instancias. Por la noche: 2 instancias. Ahorro de costo automático.

---

## Ciclo de vida completo

```
1. CREAR:
   Launch Template define la receta
   ASG crea 3 instancias (desired=3)
   ASG las registra en el ALB Target Group
   ALB comienza a enviarles tráfico

2. ESCALAR HACIA ARRIBA:
   CloudWatch detecta CPU > 80%
   Alarma activa la Scale Out Policy
   ASG crea 2 instancias nuevas (usando el Launch Template)
   Las registra en el Target Group
   ALB comienza a enviarles tráfico

3. ESCALAR HACIA ABAJO:
   CloudWatch detecta CPU < 50%
   ASG elimina instancias sobrantes
   Las elimina del Target Group
   El ALB deja de enviarles tráfico

4. REEMPLAZO DE INSTANCIA FALLIDA:
   Health Check del ALB detecta instancia no sana
   ASG elimina la instancia fallida
   ASG crea una nueva
   Todo automático, sin intervención humana
```

---

## Ejercicios propuestos

1. Cambia `desired_capacity` de 3 a 5 y ejecuta `terraform apply`. Verifica con `terraform state list` que hay 5 instancias.

2. Añade una segunda política de Step Scaling para scale-in (reducir instancias cuando la CPU está baja: < 30% por 5 minutos).

3. Modifica el `user_data` del Launch Template para escribir el `instance_type` en el HTML de respuesta. Crea una nueva versión del template. ¿Cómo afecta esto al ASG?

4. Agrega un Scheduled Scaling para el fin de semana que ponga `desired=1` (menos tráfico, menos costo).

5. Agrega el parámetro `instance_warmup = 300` a la Target Tracking Policy. ¿Qué hace este parámetro?
