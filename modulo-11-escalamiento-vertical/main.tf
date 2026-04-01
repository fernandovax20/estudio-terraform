# ============================================================
# MÓDULO 11: ESCALAMIENTO VERTICAL - Load Balancers (ALB/NLB)
# ============================================================
# Aprenderás:
#   - Application Load Balancer (ALB) - Capa 7 (HTTP/HTTPS)
#   - Network Load Balancer (NLB) - Capa 4 (TCP/UDP)
#   - Target Groups (grupos de destino)
#   - Listeners y reglas de enrutamiento
#   - Health Checks (verificaciones de salud)
#   - Balanceo basado en path, host, headers
#   - Sticky sessions (afinidad de sesión)
#   - Escalamiento vertical: subir capacidad de instancias
#
# Concepto clave: ESCALAMIENTO VERTICAL (Scale Up)
#   = Aumentar los recursos de una máquina existente
#     (más CPU, RAM, disco) en lugar de agregar más máquinas.
#   El Load Balancer distribuye tráfico entre instancias
#   que pueden tener diferentes tamaños (capacidades).
#
# Comandos:
#   cd modulo-11-escalamiento-vertical
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
    sts            = "http://localhost:4566"
    autoscaling    = "http://localhost:4566"
  }
}

variable "entorno" {
  type    = string
  default = "dev"
}

locals {
  prefijo = "lab-${var.entorno}"
  tags = {
    proyecto = "estudio-terraform"
    modulo   = "11-escalamiento-vertical"
    entorno  = var.entorno
  }
}

# ===========================================================
# RED BASE (VPC, Subnets, Security Groups)
# ===========================================================

resource "aws_vpc" "main" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = merge(local.tags, { Name = "${local.prefijo}-vpc-lb" })
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${local.prefijo}-igw" })
}

resource "aws_subnet" "publica_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.10.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
  tags = merge(local.tags, { Name = "${local.prefijo}-pub-a" })
}

resource "aws_subnet" "publica_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.10.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true
  tags = merge(local.tags, { Name = "${local.prefijo}-pub-b" })
}

resource "aws_subnet" "privada_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.10.101.0/24"
  availability_zone = "us-east-1a"
  tags = merge(local.tags, { Name = "${local.prefijo}-priv-a" })
}

resource "aws_subnet" "privada_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.10.102.0/24"
  availability_zone = "us-east-1b"
  tags = merge(local.tags, { Name = "${local.prefijo}-priv-b" })
}

resource "aws_route_table" "publica" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = merge(local.tags, { Name = "${local.prefijo}-rt-pub" })
}

resource "aws_route_table_association" "pub_a" {
  subnet_id      = aws_subnet.publica_a.id
  route_table_id = aws_route_table.publica.id
}

resource "aws_route_table_association" "pub_b" {
  subnet_id      = aws_subnet.publica_b.id
  route_table_id = aws_route_table.publica.id
}

# --------------------------------------------------
# SECURITY GROUPS
# --------------------------------------------------

# SG para el Load Balancer (acepta tráfico HTTP/HTTPS público)
resource "aws_security_group" "alb" {
  name        = "${local.prefijo}-sg-alb"
  description = "Trafico entrante al ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP publico"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS publico"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.prefijo}-sg-alb" })
}

# SG para las instancias (solo acepta tráfico del ALB)
resource "aws_security_group" "instancias" {
  name        = "${local.prefijo}-sg-instancias"
  description = "Trafico solo desde el ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP desde ALB"
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

  tags = merge(local.tags, { Name = "${local.prefijo}-sg-instancias" })
}

# ===========================================================
# INSTANCIAS EC2 - Diferentes tamaños (escalamiento vertical)
# ===========================================================
# Escalamiento vertical = cambiar el tipo de instancia
# (t2.micro → t2.small → t2.medium → t2.large)

variable "instancias" {
  description = "Instancias con diferentes capacidades (escala vertical)"
  type = map(object({
    tipo_instancia = string
    subnet         = string    # "a" o "b"
    descripcion    = string
  }))
  default = {
    # Instancia pequeña: para tráfico bajo
    "web-small" = {
      tipo_instancia = "t2.micro"
      subnet         = "a"
      descripcion    = "Instancia pequeña - 1 vCPU, 1 GB RAM"
    }
    # Instancia mediana: escalada verticalmente
    "web-medium" = {
      tipo_instancia = "t2.medium"
      subnet         = "b"
      descripcion    = "Instancia mediana - 2 vCPU, 4 GB RAM"
    }
    # Instancia grande: máxima capacidad vertical
    "web-large" = {
      tipo_instancia = "t2.large"
      subnet         = "a"
      descripcion    = "Instancia grande - 2 vCPU, 8 GB RAM"
    }
  }
}

# AMI de Amazon Linux (simulada en LocalStack)
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_instance" "servidores" {
  for_each = var.instancias

  ami           = "ami-0123456789abcdef0"  # AMI simulada en LocalStack
  instance_type = each.value.tipo_instancia
  subnet_id     = each.value.subnet == "a" ? aws_subnet.privada_a.id : aws_subnet.privada_b.id

  vpc_security_group_ids = [aws_security_group.instancias.id]

  # User data: script que se ejecuta al iniciar la instancia
  user_data = base64encode(<<-SCRIPT
    #!/bin/bash
    echo "Servidor ${each.key} iniciado" > /var/log/startup.log
    echo "Tipo: ${each.value.tipo_instancia}"
    echo "Descripción: ${each.value.descripcion}"
  SCRIPT
  )

  tags = merge(local.tags, {
    Name              = "${local.prefijo}-${each.key}"
    tipo_instancia    = each.value.tipo_instancia
    escala            = "vertical"
    descripcion       = each.value.descripcion
  })
}

# ===========================================================
# APPLICATION LOAD BALANCER (ALB) - Capa 7
# ===========================================================
# El ALB distribuye tráfico HTTP/HTTPS de forma inteligente.
# Puede enrutar según path, host header, query string, etc.

resource "aws_lb" "aplicacion" {
  name               = "${local.prefijo}-alb"
  internal           = false                    # Público (accesible desde Internet)
  load_balancer_type = "application"            # ALB (no NLB)
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.publica_a.id, aws_subnet.publica_b.id]

  # Protección contra eliminación accidental
  enable_deletion_protection = false  # true en producción

  tags = merge(local.tags, {
    Name = "${local.prefijo}-alb"
    tipo = "application"
  })
}

# --------------------------------------------------
# TARGET GROUPS (grupos de destino)
# --------------------------------------------------
# Un Target Group agrupa las instancias que recibirán tráfico.
# El ALB envía tráfico al Target Group que coincida con las reglas.

# Target Group principal (todas las instancias)
resource "aws_lb_target_group" "principal" {
  name        = "${local.prefijo}-tg-principal"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  # Health check: cómo el ALB verifica que la instancia está sana
  health_check {
    enabled             = true
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 3     # Exitosos consecutivos para marcarse sano
    unhealthy_threshold = 3     # Fallidos consecutivos para marcarse enfermo
    timeout             = 5     # Segundos de espera por respuesta
    interval            = 30    # Segundos entre checks
    matcher             = "200" # Código HTTP esperado
  }

  # Sticky sessions: mantener usuario en la misma instancia
  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400  # 1 día
    enabled         = true
  }

  tags = merge(local.tags, { Name = "${local.prefijo}-tg-principal" })
}

# Target Group para instancias grandes (tráfico pesado)
resource "aws_lb_target_group" "alto_rendimiento" {
  name        = "${local.prefijo}-tg-highperf"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    enabled  = true
    path     = "/health"
    protocol = "HTTP"
    matcher  = "200"
  }

  tags = merge(local.tags, { Name = "${local.prefijo}-tg-highperf" })
}

# --------------------------------------------------
# REGISTRAR INSTANCIAS EN TARGET GROUPS
# --------------------------------------------------
resource "aws_lb_target_group_attachment" "todas" {
  for_each = aws_instance.servidores

  target_group_arn = aws_lb_target_group.principal.arn
  target_id        = each.value.id
  port             = 8080
}

# Solo la instancia grande en el target group de alto rendimiento
resource "aws_lb_target_group_attachment" "solo_grande" {
  target_group_arn = aws_lb_target_group.alto_rendimiento.arn
  target_id        = aws_instance.servidores["web-large"].id
  port             = 8080
}

# --------------------------------------------------
# LISTENER: Reglas de enrutamiento del ALB
# --------------------------------------------------

# Listener HTTP (puerto 80) - acción por defecto
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.aplicacion.arn
  port              = 80
  protocol          = "HTTP"

  # Acción por defecto: enviar al target group principal
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.principal.arn
  }

  tags = local.tags
}

# --------------------------------------------------
# REGLAS DE ENRUTAMIENTO (path-based routing)
# --------------------------------------------------

# Ruta /api/* → target group de alto rendimiento
resource "aws_lb_listener_rule" "api_route" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alto_rendimiento.arn
  }

  condition {
    path_pattern {
      values = ["/api/*", "/graphql"]
    }
  }

  tags = local.tags
}

# Ruta /static/* → respuesta fija (sin backend)
resource "aws_lb_listener_rule" "static_response" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 200

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/html"
      message_body = "<h1>Contenido estático servido por ALB</h1>"
      status_code  = "200"
    }
  }

  condition {
    path_pattern {
      values = ["/static/*"]
    }
  }

  tags = local.tags
}

# Regla por header: admin panel solo con header especial
resource "aws_lb_listener_rule" "admin_header" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 50

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alto_rendimiento.arn
  }

  condition {
    http_header {
      http_header_name = "X-Admin-Access"
      values           = ["true"]
    }
  }

  tags = local.tags
}

# ===========================================================
# NETWORK LOAD BALANCER (NLB) - Capa 4
# ===========================================================
# El NLB opera a nivel TCP/UDP, es más rápido que el ALB
# pero no entiende HTTP. Ideal para tráfico de alta velocidad.

resource "aws_lb" "red" {
  name               = "${local.prefijo}-nlb"
  internal           = true                  # Interno (no público)
  load_balancer_type = "network"             # NLB
  subnets            = [aws_subnet.privada_a.id, aws_subnet.privada_b.id]

  tags = merge(local.tags, {
    Name = "${local.prefijo}-nlb"
    tipo = "network"
  })
}

resource "aws_lb_target_group" "tcp" {
  name        = "${local.prefijo}-tg-tcp"
  port        = 3306
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    enabled  = true
    protocol = "TCP"
    port     = "traffic-port"
  }

  tags = merge(local.tags, { Name = "${local.prefijo}-tg-tcp" })
}

resource "aws_lb_listener" "tcp" {
  load_balancer_arn = aws_lb.red.arn
  port              = 3306
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tcp.arn
  }

  tags = local.tags
}

# ===========================================================
# OUTPUTS
# ===========================================================
output "alb_dns" {
  description = "DNS del Application Load Balancer"
  value       = aws_lb.aplicacion.dns_name
}

output "alb_arn" {
  value = aws_lb.aplicacion.arn
}

output "nlb_dns" {
  description = "DNS del Network Load Balancer"
  value       = aws_lb.red.dns_name
}

output "instancias" {
  description = "Instancias con su tipo (escala vertical)"
  value = { for k, v in aws_instance.servidores : k => {
    id             = v.id
    tipo_instancia = v.instance_type
    subnet         = v.subnet_id
  }}
}

output "target_groups" {
  value = {
    principal        = aws_lb_target_group.principal.arn
    alto_rendimiento = aws_lb_target_group.alto_rendimiento.arn
    tcp              = aws_lb_target_group.tcp.arn
  }
}

output "diagrama_alb" {
  value = <<-EOF

    ┌─────────────────────────────────────────────────────────────┐
    │                     INTERNET                                │
    └──────────────────────┬──────────────────────────────────────┘
                           │
                  ┌────────▼────────┐
                  │   ALB (Capa 7)  │  ← HTTP/HTTPS público
                  │   Puerto 80     │
                  └───┬────┬────┬───┘
         ┌────────────┘    │    └──────────────┐
         │ path: /*        │ path: /api/*      │ header: X-Admin
         ▼                 ▼                   ▼
    ┌─────────────┐  ┌─────────────┐     ┌─────────────┐
    │ TG Principal│  │ TG HighPerf │     │ TG HighPerf │
    ├─────────────┤  ├─────────────┤     │ (reutilizado)│
    │ t2.micro    │  │ t2.large    │     └─────────────┘
    │ t2.medium   │  │             │
    │ t2.large    │  │             │
    └─────────────┘  └─────────────┘

    ESCALAMIENTO VERTICAL:
    t2.micro  → 1 vCPU,  1 GB RAM  (bajo tráfico)
    t2.medium → 2 vCPU,  4 GB RAM  (medio tráfico) ↑ Scale Up
    t2.large  → 2 vCPU,  8 GB RAM  (alto tráfico)  ↑↑ Scale Up

  EOF
}

# --------------------------------------------------
# EJERCICIOS PROPUESTOS:
# --------------------------------------------------
# 1. Agrega una instancia "web-xlarge" tipo t2.xlarge al mapa.
#    Esto es escalamiento vertical. Observa el plan.
#
# 2. Crea una nueva regla de listener que redirija /docs/*
#    a una URL externa (acción redirect).
#
# 3. Cambia el health check path a "/status" y el interval a 10.
#
# 4. Deshabilita sticky sessions y observa la diferencia.
#
# 5. Crea un segundo NLB para Redis (puerto 6379).
#
# 6. Cambia una instancia de t2.micro a t2.large.
#    ¿Terraform la destruye y recrea o la actualiza in-place?
