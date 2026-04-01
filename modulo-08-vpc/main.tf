# ============================================================
# MÓDULO 08: VPC - Redes virtuales en la nube
# ============================================================
# Aprenderás:
#   - VPC (Virtual Private Cloud)
#   - Subnets públicas y privadas
#   - Internet Gateway
#   - NAT Gateway
#   - Route Tables y Routes
#   - Security Groups (firewalls)
#   - CIDR blocks (notación de redes)
#   - cidrsubnet() function de Terraform
#
# Comandos:
#   cd modulo-08-vpc
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
    ec2 = "http://localhost:4566"
    sts = "http://localhost:4566"
  }
}

variable "entorno" {
  type    = string
  default = "dev"
}

variable "vpc_cidr" {
  description = "Bloque CIDR para la VPC (rango de IPs)"
  type        = string
  default     = "10.0.0.0/16"  # 65,536 IPs disponibles
}

variable "zonas_disponibilidad" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

locals {
  prefijo = "lab-${var.entorno}"
  tags = {
    proyecto = "estudio-terraform"
    modulo   = "08-vpc"
  }

  # Calcular CIDRs para subnets automáticamente
  # cidrsubnet(base, newbits, netnum) divide el CIDR base
  # /16 + 8 bits = /24 (256 IPs por subnet)
  subnets_publicas = {
    for idx, az in var.zonas_disponibilidad :
    az => cidrsubnet(var.vpc_cidr, 8, idx)
    # az => "10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24"
  }

  subnets_privadas = {
    for idx, az in var.zonas_disponibilidad :
    az => cidrsubnet(var.vpc_cidr, 8, idx + 100)
    # az => "10.0.100.0/24", "10.0.101.0/24", "10.0.102.0/24"
  }
}

# --------------------------------------------------
# VPC (Red Virtual Principal)
# --------------------------------------------------
resource "aws_vpc" "principal" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, {
    Name = "${local.prefijo}-vpc"
  })
}

# --------------------------------------------------
# INTERNET GATEWAY (Salida a Internet)
# --------------------------------------------------
# El IGW permite que los recursos en subnets públicas
# accedan a Internet y sean accesibles desde Internet.
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.principal.id

  tags = merge(local.tags, {
    Name = "${local.prefijo}-igw"
  })
}

# --------------------------------------------------
# SUBNETS PÚBLICAS (una por zona de disponibilidad)
# --------------------------------------------------
resource "aws_subnet" "publicas" {
  for_each = local.subnets_publicas

  vpc_id                  = aws_vpc.principal.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true  # IPs públicas automáticas

  tags = merge(local.tags, {
    Name = "${local.prefijo}-publica-${each.key}"
    tipo = "publica"
  })
}

# --------------------------------------------------
# SUBNETS PRIVADAS
# --------------------------------------------------
resource "aws_subnet" "privadas" {
  for_each = local.subnets_privadas

  vpc_id            = aws_vpc.principal.id
  cidr_block        = each.value
  availability_zone = each.key

  tags = merge(local.tags, {
    Name = "${local.prefijo}-privada-${each.key}"
    tipo = "privada"
  })
}

# --------------------------------------------------
# ELASTIC IP + NAT GATEWAY
# --------------------------------------------------
# El NAT Gateway permite que las subnets privadas
# accedan a Internet (sin ser accesibles desde Internet).
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.tags, {
    Name = "${local.prefijo}-nat-eip"
  })

  depends_on = [aws_internet_gateway.igw]
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = values(aws_subnet.publicas)[0].id  # En la primera subnet pública

  tags = merge(local.tags, {
    Name = "${local.prefijo}-nat-gw"
  })

  depends_on = [aws_internet_gateway.igw]
}

# --------------------------------------------------
# ROUTE TABLES (Tablas de enrutamiento)
# --------------------------------------------------

# Route Table PÚBLICA: tráfico va al Internet Gateway
resource "aws_route_table" "publica" {
  vpc_id = aws_vpc.principal.id

  route {
    cidr_block = "0.0.0.0/0"  # Todo el tráfico externo
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = merge(local.tags, {
    Name = "${local.prefijo}-rt-publica"
  })
}

# Route Table PRIVADA: tráfico va al NAT Gateway
resource "aws_route_table" "privada" {
  vpc_id = aws_vpc.principal.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = merge(local.tags, {
    Name = "${local.prefijo}-rt-privada"
  })
}

# Asociar subnets públicas con route table pública
resource "aws_route_table_association" "publicas" {
  for_each = aws_subnet.publicas

  subnet_id      = each.value.id
  route_table_id = aws_route_table.publica.id
}

# Asociar subnets privadas con route table privada
resource "aws_route_table_association" "privadas" {
  for_each = aws_subnet.privadas

  subnet_id      = each.value.id
  route_table_id = aws_route_table.privada.id
}

# --------------------------------------------------
# SECURITY GROUPS (Firewalls virtuales)
# --------------------------------------------------

# SG para servidores web (público)
resource "aws_security_group" "web" {
  name        = "${local.prefijo}-sg-web"
  description = "Permitir trafico HTTP/HTTPS"
  vpc_id      = aws_vpc.principal.id

  # Regla de entrada: HTTP
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Regla de entrada: HTTPS
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Regla de salida: permitir todo
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.prefijo}-sg-web"
  })
}

# SG para base de datos (privado)
resource "aws_security_group" "db" {
  name        = "${local.prefijo}-sg-db"
  description = "Solo permitir trafico desde el SG web"
  vpc_id      = aws_vpc.principal.id

  # Solo aceptar conexiones desde el security group web
  ingress {
    description     = "PostgreSQL desde web"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }

  ingress {
    description     = "MySQL desde web"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.prefijo}-sg-db"
  })
}

# SG para aplicaciones internas
resource "aws_security_group" "app" {
  name        = "${local.prefijo}-sg-app"
  description = "Trafico de aplicaciones internas"
  vpc_id      = aws_vpc.principal.id

  ingress {
    description     = "Desde web tier"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.prefijo}-sg-app"
  })
}

# --------------------------------------------------
# OUTPUTS
# --------------------------------------------------
output "vpc_id" {
  value = aws_vpc.principal.id
}

output "vpc_cidr" {
  value = aws_vpc.principal.cidr_block
}

output "subnets_publicas" {
  value = { for k, s in aws_subnet.publicas : k => {
    id   = s.id
    cidr = s.cidr_block
  }}
}

output "subnets_privadas" {
  value = { for k, s in aws_subnet.privadas : k => {
    id   = s.id
    cidr = s.cidr_block
  }}
}

output "security_groups" {
  value = {
    web = aws_security_group.web.id
    db  = aws_security_group.db.id
    app = aws_security_group.app.id
  }
}

output "diagrama_red" {
  description = "Diagrama ASCII de la arquitectura"
  value       = <<-EOF

    ┌─────────────────────────────────────────────────────────┐
    │                    VPC: ${var.vpc_cidr}                    │
    │                                                         │
    │  ┌──────────────────────────────────────────────────┐   │
    │  │          SUBNETS PÚBLICAS (Internet)              │   │
    │  │  ┌────────────┐ ┌────────────┐ ┌────────────┐   │   │
    │  │  │  10.0.0/24 │ │  10.0.1/24 │ │  10.0.2/24 │   │   │
    │  │  │   us-e-1a  │ │   us-e-1b  │ │   us-e-1c  │   │   │
    │  │  └────────────┘ └────────────┘ └────────────┘   │   │
    │  └──────────────────────────────────────────────────┘   │
    │                         │                               │
    │                    [NAT Gateway]                        │
    │                         │                               │
    │  ┌──────────────────────────────────────────────────┐   │
    │  │          SUBNETS PRIVADAS (sin Internet)          │   │
    │  │  ┌────────────┐ ┌────────────┐ ┌────────────┐   │   │
    │  │  │ 10.0.100/24│ │ 10.0.101/24│ │ 10.0.102/24│   │   │
    │  │  │   us-e-1a  │ │   us-e-1b  │ │   us-e-1c  │   │   │
    │  │  └────────────┘ └────────────┘ └────────────┘   │   │
    │  └──────────────────────────────────────────────────┘   │
    └─────────────────────────────────────────────────────────┘
  EOF
}

# --------------------------------------------------
# EJERCICIOS PROPUESTOS:
# --------------------------------------------------
# 1. Agrega un security group para Redis (puerto 6379)
#    que solo acepte tráfico desde el SG "app".
#
# 2. Crea una subnet adicional "aislada" (sin ruta a Internet ni NAT).
#
# 3. Modifica el SG web para permitir SSH (puerto 22) solo
#    desde tu IP (usa una variable).
#
# 4. Añade una cuarta zona de disponibilidad "us-east-1d" y
#    observa cómo Terraform calcula los CIDRs automáticamente.
#
# 5. Usa "terraform graph | dot -Tpng > graph.png" para
#    visualizar las dependencias entre recursos.
