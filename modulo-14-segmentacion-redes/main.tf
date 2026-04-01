# ============================================================
# MÓDULO 14: SEGMENTACIÓN DE REDES
# ============================================================
# Aprenderás:
#   - Múltiples VPCs (aislamiento por servicio/equipo)
#   - VPC Peering (conectar VPCs entre sí)
#   - Network ACLs (firewall a nivel de subnet)
#   - Diferencia entre SG (stateful) vs NACL (stateless)
#   - VPC Endpoints (acceso privado a servicios AWS)
#   - Prefix Lists
#   - Subnets de aislamiento (DMZ, app, datos)
#   - Segmentación por capas (3-tier architecture)
#   - Flow Logs (auditoría de tráfico)
#
# Concepto clave: SEGMENTACIÓN DE REDES
#   = Dividir la red en segmentos aislados para:
#   1. Seguridad: limitar el impacto de una brecha
#   2. Compliance: aislar datos sensibles
#   3. Organización: separar equipos/servicios
#
# Comandos:
#   cd modulo-14-segmentacion-redes
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
    ec2  = "http://localhost:4566"
    sts  = "http://localhost:4566"
    s3   = "http://localhost:4566"
    logs = "http://localhost:4566"
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
    modulo   = "14-segmentacion-redes"
    entorno  = var.entorno
  }
}

# ===========================================================
# VPC 1: PRODUCCIÓN (servicios de cara al cliente)
# ===========================================================
resource "aws_vpc" "produccion" {
  cidr_block           = "10.100.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = merge(local.tags, {
    Name     = "${local.prefijo}-vpc-produccion"
    segmento = "produccion"
  })
}

resource "aws_internet_gateway" "produccion" {
  vpc_id = aws_vpc.produccion.id
  tags   = merge(local.tags, { Name = "${local.prefijo}-igw-prod" })
}

# --- Subnets de PRODUCCIÓN (3-tier architecture) ---

# Tier 1: DMZ (zona desmilitarizada) - Load Balancers, WAF
resource "aws_subnet" "prod_dmz" {
  count                   = 2
  vpc_id                  = aws_vpc.produccion.id
  cidr_block              = cidrsubnet("10.100.0.0/16", 8, count.index)
  availability_zone       = "us-east-1${["a", "b"][count.index]}"
  map_public_ip_on_launch = true
  tags = merge(local.tags, {
    Name = "${local.prefijo}-prod-dmz-${count.index}"
    tier = "dmz"
    acceso = "publico"
  })
}

# Tier 2: Aplicación - Servidores de app, APIs
resource "aws_subnet" "prod_app" {
  count             = 2
  vpc_id            = aws_vpc.produccion.id
  cidr_block        = cidrsubnet("10.100.0.0/16", 8, count.index + 10)
  availability_zone = "us-east-1${["a", "b"][count.index]}"
  tags = merge(local.tags, {
    Name = "${local.prefijo}-prod-app-${count.index}"
    tier = "aplicacion"
    acceso = "privado"
  })
}

# Tier 3: Datos - Bases de datos, cache
resource "aws_subnet" "prod_datos" {
  count             = 2
  vpc_id            = aws_vpc.produccion.id
  cidr_block        = cidrsubnet("10.100.0.0/16", 8, count.index + 20)
  availability_zone = "us-east-1${["a", "b"][count.index]}"
  tags = merge(local.tags, {
    Name = "${local.prefijo}-prod-datos-${count.index}"
    tier = "datos"
    acceso = "aislado"
  })
}

# ===========================================================
# VPC 2: BACKEND INTERNO (servicios internos, microservicios)
# ===========================================================
resource "aws_vpc" "backend" {
  cidr_block           = "10.200.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = merge(local.tags, {
    Name     = "${local.prefijo}-vpc-backend"
    segmento = "backend"
  })
}

resource "aws_subnet" "backend_servicios" {
  count             = 2
  vpc_id            = aws_vpc.backend.id
  cidr_block        = cidrsubnet("10.200.0.0/16", 8, count.index)
  availability_zone = "us-east-1${["a", "b"][count.index]}"
  tags = merge(local.tags, {
    Name = "${local.prefijo}-backend-svc-${count.index}"
    tier = "servicios"
  })
}

resource "aws_subnet" "backend_datos" {
  count             = 2
  vpc_id            = aws_vpc.backend.id
  cidr_block        = cidrsubnet("10.200.0.0/16", 8, count.index + 10)
  availability_zone = "us-east-1${["a", "b"][count.index]}"
  tags = merge(local.tags, {
    Name = "${local.prefijo}-backend-datos-${count.index}"
    tier = "datos"
  })
}

# ===========================================================
# VPC 3: MANAGEMENT (CI/CD, monitoring, logging)
# ===========================================================
resource "aws_vpc" "management" {
  cidr_block           = "10.50.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = merge(local.tags, {
    Name     = "${local.prefijo}-vpc-mgmt"
    segmento = "management"
  })
}

resource "aws_subnet" "mgmt_tools" {
  count             = 2
  vpc_id            = aws_vpc.management.id
  cidr_block        = cidrsubnet("10.50.0.0/16", 8, count.index)
  availability_zone = "us-east-1${["a", "b"][count.index]}"
  tags = merge(local.tags, {
    Name = "${local.prefijo}-mgmt-tools-${count.index}"
    tier = "herramientas"
  })
}

# ===========================================================
# VPC PEERING: Conectar VPCs entre sí
# ===========================================================
# El VPC Peering permite tráfico directo entre dos VPCs.
# Es una conexión punto a punto NO transitiva
# (si A↔B y B↔C, A NO puede hablar con C automáticamente).

# Peering: Producción ↔ Backend
resource "aws_vpc_peering_connection" "prod_to_backend" {
  vpc_id      = aws_vpc.produccion.id     # Solicitante
  peer_vpc_id = aws_vpc.backend.id        # Aceptante
  auto_accept = true                       # En misma cuenta, acepta auto

  tags = merge(local.tags, {
    Name = "${local.prefijo}-peer-prod-backend"
  })
}

# Peering: Management ↔ Producción
resource "aws_vpc_peering_connection" "mgmt_to_prod" {
  vpc_id      = aws_vpc.management.id
  peer_vpc_id = aws_vpc.produccion.id
  auto_accept = true

  tags = merge(local.tags, {
    Name = "${local.prefijo}-peer-mgmt-prod"
  })
}

# Peering: Management ↔ Backend
resource "aws_vpc_peering_connection" "mgmt_to_backend" {
  vpc_id      = aws_vpc.management.id
  peer_vpc_id = aws_vpc.backend.id
  auto_accept = true

  tags = merge(local.tags, {
    Name = "${local.prefijo}-peer-mgmt-backend"
  })
}

# --------------------------------------------------
# RUTAS para el peering (bidireccionales)
# --------------------------------------------------

# Ruta: Producción → Backend (10.200.0.0/16 via peering)
resource "aws_route_table" "prod_a_backend" {
  vpc_id = aws_vpc.produccion.id

  route {
    cidr_block                = aws_vpc.backend.cidr_block  # 10.200.0.0/16
    vpc_peering_connection_id = aws_vpc_peering_connection.prod_to_backend.id
  }

  route {
    cidr_block                = aws_vpc.management.cidr_block  # 10.50.0.0/16
    vpc_peering_connection_id = aws_vpc_peering_connection.mgmt_to_prod.id
  }

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.produccion.id
  }

  tags = merge(local.tags, { Name = "${local.prefijo}-rt-prod" })
}

# Ruta: Backend → Producción y Management
resource "aws_route_table" "backend_peers" {
  vpc_id = aws_vpc.backend.id

  route {
    cidr_block                = aws_vpc.produccion.cidr_block
    vpc_peering_connection_id = aws_vpc_peering_connection.prod_to_backend.id
  }

  route {
    cidr_block                = aws_vpc.management.cidr_block
    vpc_peering_connection_id = aws_vpc_peering_connection.mgmt_to_backend.id
  }

  tags = merge(local.tags, { Name = "${local.prefijo}-rt-backend" })
}

# Ruta: Management → Producción y Backend
resource "aws_route_table" "mgmt_peers" {
  vpc_id = aws_vpc.management.id

  route {
    cidr_block                = aws_vpc.produccion.cidr_block
    vpc_peering_connection_id = aws_vpc_peering_connection.mgmt_to_prod.id
  }

  route {
    cidr_block                = aws_vpc.backend.cidr_block
    vpc_peering_connection_id = aws_vpc_peering_connection.mgmt_to_backend.id
  }

  tags = merge(local.tags, { Name = "${local.prefijo}-rt-mgmt" })
}

# ===========================================================
# NETWORK ACLs (Firewall a nivel de Subnet)
# ===========================================================
# Las NACLs son STATELESS (necesitas reglas de entrada Y salida)
# vs Security Groups que son STATEFUL (respuestas van automáticas).

# NACL para la DMZ: solo HTTP/HTTPS desde Internet
resource "aws_network_acl" "dmz" {
  vpc_id     = aws_vpc.produccion.id
  subnet_ids = aws_subnet.prod_dmz[*].id

  # === REGLAS DE ENTRADA (ingress) ===

  # Permitir HTTP
  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }

  # Permitir HTTPS
  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  # Permitir respuestas (puertos efímeros)
  ingress {
    rule_no    = 200
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # Denegar todo lo demás (regla implícita, pero la hacemos explícita)
  ingress {
    rule_no    = 999
    protocol   = "-1"
    action     = "deny"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  # === REGLAS DE SALIDA (egress) ===

  egress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }

  egress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  # Puertos efímeros para respuestas
  egress {
    rule_no    = 200
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # Permitir tráfico al tier de aplicación
  egress {
    rule_no    = 300
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "10.100.10.0/24"  # Subnet de app
    from_port  = 8080
    to_port    = 8080
  }

  tags = merge(local.tags, {
    Name = "${local.prefijo}-nacl-dmz"
    tier = "dmz"
  })
}

# NACL para la capa de datos: MUY restrictiva
resource "aws_network_acl" "datos" {
  vpc_id     = aws_vpc.produccion.id
  subnet_ids = aws_subnet.prod_datos[*].id

  # Solo permitir tráfico desde la subnet de aplicación
  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "10.100.10.0/24"  # Solo desde subnet app
    from_port  = 5432
    to_port    = 5432              # PostgreSQL
  }

  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "10.100.10.0/24"
    from_port  = 3306
    to_port    = 3306              # MySQL
  }

  ingress {
    rule_no    = 120
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "10.100.10.0/24"
    from_port  = 6379
    to_port    = 6379              # Redis
  }

  # Puertos efímeros para respuestas
  ingress {
    rule_no    = 200
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "10.100.0.0/16"
    from_port  = 1024
    to_port    = 65535
  }

  ingress {
    rule_no    = 999
    protocol   = "-1"
    action     = "deny"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  # Salida solo hacia la VPC interna
  egress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "10.100.0.0/16"
    from_port  = 1024
    to_port    = 65535
  }

  egress {
    rule_no    = 999
    protocol   = "-1"
    action     = "deny"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  tags = merge(local.tags, {
    Name = "${local.prefijo}-nacl-datos"
    tier = "datos"
  })
}

# ===========================================================
# SECURITY GROUPS ENTRE VPCs (vía peering)
# ===========================================================

# SG en VPC Producción: permite tráfico desde VPC Backend
resource "aws_security_group" "prod_desde_backend" {
  name        = "${local.prefijo}-sg-prod-desde-backend"
  description = "Trafico desde VPC Backend via peering"
  vpc_id      = aws_vpc.produccion.id

  ingress {
    description = "API interna desde Backend"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.backend.cidr_block]
  }

  ingress {
    description = "gRPC desde Backend"
    from_port   = 50051
    to_port     = 50051
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.backend.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.prefijo}-sg-prod-from-backend" })
}

# SG en VPC Management: permite monitoreo hacia todas las VPCs
resource "aws_security_group" "mgmt_monitoreo" {
  name        = "${local.prefijo}-sg-mgmt-monitoring"
  description = "Monitoreo desde Management hacia todas las VPCs"
  vpc_id      = aws_vpc.management.id

  # Permitir Prometheus scraping
  egress {
    description = "Prometheus hacia Produccion"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.produccion.cidr_block]
  }

  egress {
    description = "Prometheus hacia Backend"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.backend.cidr_block]
  }

  # SSH para administración
  egress {
    description = "SSH admin"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  ingress {
    description = "HTTPS dashboard"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  tags = merge(local.tags, { Name = "${local.prefijo}-sg-mgmt-monitoring" })
}

# ===========================================================
# VPC ENDPOINTS (Acceso privado a servicios AWS)
# ===========================================================
# Sin VPC Endpoints, el tráfico a S3/DynamoDB sale por Internet.
# Con VPC Endpoints, el tráfico va por la red interna de AWS.

# Gateway Endpoint para S3 (gratuito, más común)
resource "aws_vpc_endpoint" "s3_produccion" {
  vpc_id       = aws_vpc.produccion.id
  service_name = "com.amazonaws.us-east-1.s3"

  tags = merge(local.tags, {
    Name    = "${local.prefijo}-vpce-s3-prod"
    servicio = "s3"
  })
}

# Gateway Endpoint para DynamoDB
resource "aws_vpc_endpoint" "dynamodb_produccion" {
  vpc_id       = aws_vpc.produccion.id
  service_name = "com.amazonaws.us-east-1.dynamodb"

  tags = merge(local.tags, {
    Name    = "${local.prefijo}-vpce-dynamodb-prod"
    servicio = "dynamodb"
  })
}

# Endpoint también en la VPC Backend
resource "aws_vpc_endpoint" "s3_backend" {
  vpc_id       = aws_vpc.backend.id
  service_name = "com.amazonaws.us-east-1.s3"

  tags = merge(local.tags, {
    Name    = "${local.prefijo}-vpce-s3-backend"
    servicio = "s3"
  })
}

# ===========================================================
# VPC FLOW LOGS (Auditoría de tráfico)
# ===========================================================
# Flow Logs registran todo el tráfico de red de una VPC.
# Esencial para seguridad y debugging.

resource "aws_cloudwatch_log_group" "flow_logs_prod" {
  name              = "/${local.prefijo}/vpc-flow-logs/produccion"
  retention_in_days = 14

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "flow_logs_backend" {
  name              = "/${local.prefijo}/vpc-flow-logs/backend"
  retention_in_days = 14

  tags = local.tags
}

# ===========================================================
# OUTPUTS
# ===========================================================
output "vpcs" {
  description = "VPCs creadas y sus CIDRs"
  value = {
    produccion = {
      id   = aws_vpc.produccion.id
      cidr = aws_vpc.produccion.cidr_block
    }
    backend = {
      id   = aws_vpc.backend.id
      cidr = aws_vpc.backend.cidr_block
    }
    management = {
      id   = aws_vpc.management.id
      cidr = aws_vpc.management.cidr_block
    }
  }
}

output "peering_connections" {
  value = {
    prod_backend = aws_vpc_peering_connection.prod_to_backend.id
    mgmt_prod    = aws_vpc_peering_connection.mgmt_to_prod.id
    mgmt_backend = aws_vpc_peering_connection.mgmt_to_backend.id
  }
}

output "vpc_endpoints" {
  value = {
    s3_prod       = aws_vpc_endpoint.s3_produccion.id
    dynamodb_prod = aws_vpc_endpoint.dynamodb_produccion.id
    s3_backend    = aws_vpc_endpoint.s3_backend.id
  }
}

output "subnets_produccion" {
  value = {
    dmz  = [for s in aws_subnet.prod_dmz : { id = s.id, cidr = s.cidr_block }]
    app  = [for s in aws_subnet.prod_app : { id = s.id, cidr = s.cidr_block }]
    data = [for s in aws_subnet.prod_datos : { id = s.id, cidr = s.cidr_block }]
  }
}

output "diagrama_segmentacion" {
  value = <<-EOF

    ═══════════════════════════════════════════════════════════════
                    SEGMENTACIÓN DE REDES
    ═══════════════════════════════════════════════════════════════

    ┌─────────────────────────────────────────────────────────────┐
    │              VPC MANAGEMENT (10.50.0.0/16)                  │
    │   CI/CD, Monitoring, Logging, Admin tools                   │
    │   ┌─────────────┐  ┌─────────────┐                         │
    │   │ mgmt-tools-0│  │ mgmt-tools-1│                         │
    │   └──────┬──────┘  └──────┬──────┘                         │
    └──────────┼────────────────┼─────────────────────────────────┘
               │ VPC Peering    │ VPC Peering
        ┌──────┴───┐     ┌─────┴────┐
        │          │     │          │
    ┌───┴──────────┴─────┴──────────┴────────────────────────────┐
    │              VPC PRODUCCIÓN (10.100.0.0/16)                 │
    │                                                             │
    │  Tier 1: DMZ ─────────────────────── (público)             │
    │  ┌──────────┐  ┌──────────┐                                │
    │  │ dmz-0    │  │ dmz-1    │  ← ALB, WAF                   │
    │  │10.100.0/24│ │10.100.1/24│  ← NACL: solo HTTP/HTTPS     │
    │  └─────┬────┘  └─────┬────┘                                │
    │        └──────┬──────┘                                     │
    │  Tier 2: APP ─┴──────────────── (privado)                  │
    │  ┌──────────┐  ┌──────────┐                                │
    │  │ app-0    │  │ app-1    │  ← Servidores, APIs            │
    │  │10.100.10/24│ │10.100.11/24│                              │
    │  └─────┬────┘  └─────┬────┘                                │
    │        └──────┬──────┘                                     │
    │  Tier 3: DATOS ┴──────────────── (aislado)                 │
    │  ┌──────────┐  ┌──────────┐                                │
    │  │ datos-0  │  │ datos-1  │  ← DB, Redis, Cache            │
    │  │10.100.20/24│ │10.100.21/24│  ← NACL: SOLO desde app tier│
    │  └──────────┘  └──────────┘                                │
    └───────────────────────┬────────────────────────────────────┘
                            │ VPC Peering
    ┌───────────────────────┴────────────────────────────────────┐
    │              VPC BACKEND (10.200.0.0/16)                   │
    │   Microservicios internos, procesamiento batch             │
    │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
    │  │ svc-0    │  │ svc-1    │  │ datos-0  │  │ datos-1  │  │
    │  └──────────┘  └──────────┘  └──────────┘  └──────────┘  │
    └────────────────────────────────────────────────────────────┘

    VPC Endpoints: S3 y DynamoDB accesibles sin salir a Internet

    NACL (stateless) vs Security Group (stateful):
    ┌────────────────────┬──────────────────────────────┐
    │ NACL               │ Security Group               │
    ├────────────────────┼──────────────────────────────┤
    │ Nivel de subnet    │ Nivel de instancia           │
    │ Stateless          │ Stateful                     │
    │ Reglas allow/deny  │ Solo allow (deny implícito)  │
    │ Evalúa por orden   │ Evalúa todas las reglas      │
    │ Primera línea      │ Segunda línea de defensa     │
    └────────────────────┴──────────────────────────────┘

  EOF
}

# --------------------------------------------------
# EJERCICIOS PROPUESTOS:
# --------------------------------------------------
# 1. Agrega una VPC "staging" (10.150.0.0/16) con peering
#    solo hacia management (no hacia producción).
#
# 2. Crea una NACL para el tier de aplicación que:
#    - Permita tráfico 8080 desde DMZ
#    - Permita tráfico a puertos 5432, 3306, 6379 hacia datos
#    - Deniegue todo lo demás
#
# 3. Agrega un VPC Endpoint de tipo "Interface" para SQS.
#    ¿Cuál es la diferencia entre Gateway e Interface endpoints?
#
# 4. Crea un security group "bastion" en Management que
#    permita SSH (22) solo desde una IP específica.
#
# 5. Investiga: Si VPC A↔B y B↔C tienen peering,
#    ¿puede A hablar directamente con C? (No: peering no es transitivo)
#
# 6. Agrega Flow Logs a la VPC de Management y observa
#    los logs en CloudWatch.
#
# 7. Crea un Prefix List con las IPs de tu oficina y úsalo
#    en múltiples security groups (en vez de repetir CIDRs).
