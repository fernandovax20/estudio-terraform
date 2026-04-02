# Módulo 11 — Escalamiento Vertical

## ¿Qué vas a aprender?

- Qué es el escalamiento vertical y cuándo usarlo
- Cómo simular EC2 con LocalStack (sin costo real)
- Crear un Application Load Balancer (ALB) en Terraform
- Configurar Target Groups con health checks
- Registrar instancias en un Target Group
- Crear Listeners que routeen tráfico al Target Group
- Usar `for_each` con un mapa de configuraciones de instancias

---

## Cómo ejecutar este módulo

```bash
docker-compose up -d
cd modulo-11-escalamiento-vertical
terraform init
terraform apply -auto-approve
terraform output
terraform destroy
```

---

## Escalamiento Vertical vs Horizontal

| | Escalamiento Vertical | Escalamiento Horizontal |
|---|---|---|
| **Qué hace** | Poner máquinas más grandes | Poner más máquinas |
| **Ejemplo** | `t2.micro → t2.xlarge` | `2 instancias → 20 instancias` |
| **Downtime** | Generalmente requiere reinicio | Sin downtime |
| **Límite** | El tamaño máximo de instancia en AWS | Prácticamente ilimitado |
| **Cuándo usarlo** | Bases de datos, caches, apps con estado | Aplicaciones web sin estado |
| **Costo** | Predecible | Variable según carga |

**Módulo 11 = escalar verticamente** (tamaño de instancia)
**Módulo 12 = escalar horizontalmente** (número de instancias)

---

## Los tipos de instancias EC2

```hcl
variable "instancias" {
  type = map(object({
    instance_type = string
    ami           = string
  }))
  default = {
    "pequena" = {
      instance_type = "t2.micro"   # 1 vCPU, 1 GB RAM
      ami           = "ami-test"
    }
    "mediana" = {
      instance_type = "t2.medium"  # 2 vCPU, 4 GB RAM
      ami           = "ami-test"
    }
    "grande" = {
      instance_type = "t2.large"   # 2 vCPU, 8 GB RAM
      ami           = "ami-test"
    }
  }
}
```

Definir las instancias como un mapa permite crear el recurso con `for_each`:

```hcl
resource "aws_instance" "servidores" {
  for_each = var.instancias

  ami           = each.value.ami
  instance_type = each.value.instance_type

  tags = {
    Name = "servidor-${each.key}"  # "servidor-pequena", "servidor-mediana"...
  }
}
```

Para "escalar verticalmente", cambias `instance_type = "t2.medium"` a `instance_type = "t2.xlarge"` y ejecutas `terraform apply`. Terraform actualizará la instancia (o la re-creará si AWS lo requiere).

---

## Application Load Balancer (ALB)

El ALB es el punto de entrada al sistema. Distribuye las peticiones entrantes entre las instancias:

```
Cliente → ALB → [servidor-pequena]
              → [servidor-mediana]
              → [servidor-grande]
```

En Terraform, un ALB se divide en tres recursos:

```
aws_lb                  ← El balanceador en sí
aws_lb_target_group     ← El grupo de destinos (qué instancias reciben tráfico)
aws_lb_listener         ← La regla (qué tráfico se envía al target group)
```

---

## Recurso 1: `aws_lb` — El balanceador

```hcl
resource "aws_lb" "principal" {
  name               = "lb-principal-${var.entorno}"
  internal           = false           # false = accesible desde internet (externo)
  load_balancer_type = "application"   # ALB (layer 7, HTTP/HTTPS)

  # El ALB necesita subnets en la VPC
  subnets = var.subnet_ids

  enable_deletion_protection = false   # En producción, pon true
  
  tags = local.tags
}
```

`load_balancer_type` puede ser:
- `"application"` → ALB: trabaja en la capa 7 (HTTP, HTTPS, WebSocket). Puede routear por path o headers.
- `"network"` → NLB: trabaja en la capa 4 (TCP, UDP). Más rápido, sin inspección HTTP.
- `"gateway"` → GWLB: para appliances de red (firewalls, IDS).

---

## Recurso 2: `aws_lb_target_group` — Grupo de destinos

```hcl
resource "aws_lb_target_group" "app" {
  name     = "tg-app-${var.entorno}"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    enabled             = true
    healthy_threshold   = 2    # 2 checks OK para marcar sano
    unhealthy_threshold = 3    # 3 checks KO para marcar no sano
    timeout             = 5    # Espera 5 segundos la respuesta
    interval            = 30   # Hace el check cada 30 segundos
    path                = "/health"   # Endpoint del health check
    matcher             = "200"       # Código HTTP esperado
  }
}
```

El Target Group define:
- **A quién enviar el tráfico** (las instancias registradas)
- **Cómo verificar que están sanas** (health check)

Si una instancia falla el health check, el ALB deja de enviarle tráfico automáticamente.

---

## Recurso 3: Registrar instancias en el Target Group

```hcl
resource "aws_lb_target_group_attachment" "servidores" {
  for_each = aws_instance.servidores

  target_group_arn = aws_lb_target_group.app.arn
  target_id        = each.value.id   # ID de la instancia EC2
  port             = 80
}
```

`for_each = aws_instance.servidores` itera sobre todas las instancias creadas. Terraform registra cada una en el Target Group automáticamente.

---

## Recurso 4: `aws_lb_listener` — La regla de escucha

```hcl
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.principal.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
```

El Listener define: "cuando llegue tráfico al puerto 80, reenvíalo al target group `app`".

Para HTTPS, necesitarías:
```hcl
port     = 443
protocol = "HTTPS"
ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
certificate_arn = aws_acm_certificate.cert.arn
```

---

## Salidas útiles

```hcl
output "alb_dns_name" {
  value = aws_lb.principal.dns_name
  description = "Usa esta URL para acceder a la aplicación"
}

output "instancias_creadas" {
  value = {
    for k, v in aws_instance.servidores : k => {
      id   = v.id
      tipo = v.instance_type
    }
  }
}
```

---

## El proceso de escalamiento vertical

```
SITUACIÓN INICIAL:
  - servidor-pequena: t2.micro (1 vCPU, 1 GB)
  - Alto uso de CPU al 90%

DECISIÓN:
  - instance_type = "t2.medium"   # 2 vCPU, 4 GB

TERRAFORM PLAN:
  ~ aws_instance.servidores["pequena"]
      instance_type: "t2.micro" → "t2.medium"

TERRAFORM APPLY:
  - Para la instancia (si es necesario)
  - La re-inicia con el nuevo tipo
  - El ALB deja de enviarle tráfico mientras el health check falla
  - Cuando la instancia responde, el ALB vuelve a enviarle tráfico
```

---

## Diferencia entre ALB y NLB

```hcl
# Application Load Balancer
resource "aws_lb" "alb" {
  load_balancer_type = "application"
  # Soporta: routing por URL, headers, cookies
  # Ideal: aplicaciones web, microservicios
  # Latencia: ~1ms añadida
}

# Network Load Balancer
resource "aws_lb" "nlb" {
  load_balancer_type = "network"
  # Soporta: TCP, UDP, TLS passthrough
  # Ideal: gaming, IoT, baja latencia
  # Latencia: ultra-baja (<1ms)
}
```

---

## Ejercicios propuestos

1. Agrega una instancia `"extra-grande"` de tipo `t2.xlarge` al mapa de instancias. Ejecuta `terraform plan` y verifica que solo crea esa instancia sin afectar las demás.

2. Modifica el health check para que el `interval` sea de `10` segundos y el `healthy_threshold` sea `3`. Ejecuta `terraform apply`.

3. Agrega un segundo Target Group para instancias con un path `/api`. El Listener principal debe tener una regla adicional que routee URLs que empiecen por `/api/` a ese nuevo Target Group.

4. ¿Qué pasa si quitas `"mediana"` del mapa de instancias y ejecutas `terraform apply`? Haz el `plan` para ver qué va a pasar antes de aplicar.

5. Agrega un output que devuelva el ARN del listener HTTP.
