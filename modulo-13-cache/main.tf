# ============================================================
# MÓDULO 13: CACHE - ElastiCache (Redis y Memcached)
# ============================================================
# Aprenderás:
#   - ElastiCache Redis (cluster con réplicas)
#   - ElastiCache Memcached (cluster distribuido)
#   - Subnet Groups (dónde vive el cache)
#   - Parameter Groups (configuración del motor)
#   - Replication Groups (alta disponibilidad)
#   - Security Groups para cache
#   - Patrones de cache: read-through, write-behind, TTL
#   - Cuándo usar Redis vs Memcached
#
# Concepto clave: CACHE
#   = Almacenamiento intermedio ultra-rápido (en memoria)
#   Reduce latencia y carga en base de datos.
#   Redis: persiste datos, pub/sub, estructuras complejas
#   Memcached: más simple, solo key-value, multi-thread
#
# Comandos:
#   cd modulo-13-cache
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
    elasticache    = "http://localhost:4566"
    sts            = "http://localhost:4566"
    sns            = "http://localhost:4566"
    cloudwatch     = "http://localhost:4566"
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
    modulo   = "13-cache"
    entorno  = var.entorno
  }
}

# ===========================================================
# RED BASE
# ===========================================================

resource "aws_vpc" "main" {
  cidr_block           = "10.30.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = merge(local.tags, { Name = "${local.prefijo}-vpc-cache" })
}

# Subnets privadas (el cache NUNCA debe estar público)
resource "aws_subnet" "privada" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet("10.30.0.0/16", 8, count.index + 100)
  availability_zone = "us-east-1${["a", "b", "c"][count.index]}"
  tags = merge(local.tags, {
    Name = "${local.prefijo}-priv-cache-${count.index}"
  })
}

# Security Group para Redis
resource "aws_security_group" "redis" {
  name        = "${local.prefijo}-sg-redis"
  description = "Acceso al cluster Redis"
  vpc_id      = aws_vpc.main.id

  # Solo aceptar conexiones Redis (6379) desde la VPC
  ingress {
    description = "Redis desde VPC"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.prefijo}-sg-redis" })
}

# Security Group para Memcached
resource "aws_security_group" "memcached" {
  name        = "${local.prefijo}-sg-memcached"
  description = "Acceso al cluster Memcached"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Memcached desde VPC"
    from_port   = 11211
    to_port     = 11211
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.prefijo}-sg-memcached" })
}

# ===========================================================
# SUBNET GROUP (Dónde se despliegan los nodos de cache)
# ===========================================================
# ElastiCache necesita un subnet group para saber en qué
# subnets colocar los nodos del cluster.

resource "aws_elasticache_subnet_group" "cache" {
  name        = "${local.prefijo}-cache-subnets"
  description = "Subnets para clusters de cache"
  subnet_ids  = aws_subnet.privada[*].id

  tags = local.tags
}

# ===========================================================
# PARAMETER GROUP: Configuración del motor de cache
# ===========================================================
# Los parameter groups controlan el comportamiento interno
# del motor de cache (memory policy, timeouts, etc.)

# Parameter Group personalizado para Redis
resource "aws_elasticache_parameter_group" "redis_custom" {
  family      = "redis7"
  name        = "${local.prefijo}-redis-params"
  description = "Parametros customizados para Redis"

  # Política de evicción cuando se llena la memoria
  # allkeys-lru: eliminar las claves menos usadas recientemente
  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }

  # Timeout de conexiones inactivas (300 segundos)
  parameter {
    name  = "timeout"
    value = "300"
  }

  # Habilitar notificaciones de eventos (keyspace notifications)
  parameter {
    name  = "notify-keyspace-events"
    value = "Ex"  # Expiración de keys
  }

  tags = local.tags
}

# Parameter Group para Memcached
resource "aws_elasticache_parameter_group" "memcached_custom" {
  family      = "memcached1.6"
  name        = "${local.prefijo}-memcached-params"
  description = "Parametros para Memcached"

  # Tamaño máximo de item (en bytes)
  parameter {
    name  = "max_item_size"
    value = "10485760"  # 10 MB
  }

  tags = local.tags
}

# ===========================================================
# REDIS: Cluster simple (un solo nodo)
# ===========================================================
# Ideal para desarrollo y testing.

resource "aws_elasticache_cluster" "redis_simple" {
  cluster_id           = "${local.prefijo}-redis-simple"
  engine               = "redis"
  engine_version       = "7.0"
  node_type            = "cache.t3.micro"     # Tipo de instancia del nodo
  num_cache_nodes      = 1                     # Un solo nodo
  port                 = 6379
  parameter_group_name = aws_elasticache_parameter_group.redis_custom.name
  subnet_group_name    = aws_elasticache_subnet_group.cache.name
  security_group_ids   = [aws_security_group.redis.id]

  # Ventana de mantenimiento (horario de baja actividad)
  maintenance_window = "sun:05:00-sun:06:00"

  # Ventana de snapshots (backups automáticos)
  snapshot_window          = "03:00-04:00"
  snapshot_retention_limit = 3  # Retener 3 días de backups

  tags = merge(local.tags, {
    tipo    = "redis"
    modo    = "standalone"
    uso     = "desarrollo"
  })
}

# ===========================================================
# REDIS: Replication Group (alta disponibilidad)
# ===========================================================
# Un Replication Group tiene un nodo primario y réplicas.
# Si el primario falla, una réplica toma su lugar.
# Esto es lo que usarías en producción.

resource "aws_elasticache_replication_group" "redis_ha" {
  replication_group_id = "${local.prefijo}-redis-ha"
  description          = "Redis con alta disponibilidad"

  engine               = "redis"
  engine_version       = "7.0"
  node_type            = "cache.t3.micro"
  port                 = 6379
  parameter_group_name = aws_elasticache_parameter_group.redis_custom.name
  subnet_group_name    = aws_elasticache_subnet_group.cache.name
  security_group_ids   = [aws_security_group.redis.id]

  # Réplicas: 2 réplicas del nodo primario
  num_cache_clusters = 3  # 1 primario + 2 réplicas

  # Failover automático: si el primario cae, una réplica sube
  automatic_failover_enabled = true

  # Multi-AZ: distribuir nodos en diferentes zonas
  multi_az_enabled = true

  # Backups
  snapshot_retention_limit = 5
  snapshot_window          = "03:00-05:00"

  # Cifrado (seguridad)
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  # Ventana de mantenimiento
  maintenance_window = "sun:05:00-sun:07:00"

  tags = merge(local.tags, {
    tipo = "redis"
    modo = "replication-group"
    uso  = "produccion"
  })
}

# ===========================================================
# MEMCACHED: Cluster distribuido
# ===========================================================
# Memcached distribuye datos entre múltiples nodos.
# No tiene réplicas: si un nodo cae, se pierden sus datos.
# Más simple que Redis, pero más rápido para key-value puro.

resource "aws_elasticache_cluster" "memcached" {
  cluster_id           = "${local.prefijo}-memcached"
  engine               = "memcached"
  engine_version       = "1.6.22"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 3                     # 3 nodos distribuidos
  port                 = 11211
  parameter_group_name = aws_elasticache_parameter_group.memcached_custom.name
  subnet_group_name    = aws_elasticache_subnet_group.cache.name
  security_group_ids   = [aws_security_group.memcached.id]

  # AZ preferidas para los nodos
  az_mode                  = "cross-az"
  preferred_availability_zones = [
    "us-east-1a",
    "us-east-1b",
    "us-east-1c",
  ]

  maintenance_window = "sat:05:00-sat:06:00"

  tags = merge(local.tags, {
    tipo = "memcached"
    modo = "distributed"
  })
}

# ===========================================================
# MÚLTIPLES CLUSTERS CON for_each (patrón por servicio)
# ===========================================================
variable "caches_por_servicio" {
  description = "Cache dedicado por microservicio"
  type = map(object({
    engine     = string
    node_type  = string
    num_nodos  = number
  }))
  default = {
    "sesiones" = {
      engine    = "redis"
      node_type = "cache.t3.micro"
      num_nodos = 1
    }
    "catalogo" = {
      engine    = "redis"
      node_type = "cache.t3.small"
      num_nodos = 1
    }
    "api-responses" = {
      engine    = "memcached"
      node_type = "cache.t3.micro"
      num_nodos = 2
    }
  }
}

resource "aws_elasticache_cluster" "por_servicio" {
  for_each = var.caches_por_servicio

  cluster_id           = "${local.prefijo}-${each.key}"
  engine               = each.value.engine
  node_type            = each.value.node_type
  num_cache_nodes      = each.value.num_nodos
  port                 = each.value.engine == "redis" ? 6379 : 11211
  parameter_group_name = each.value.engine == "redis" ? aws_elasticache_parameter_group.redis_custom.name : aws_elasticache_parameter_group.memcached_custom.name
  subnet_group_name    = aws_elasticache_subnet_group.cache.name
  security_group_ids   = each.value.engine == "redis" ? [aws_security_group.redis.id] : [aws_security_group.memcached.id]

  tags = merge(local.tags, {
    servicio = each.key
    engine   = each.value.engine
  })
}

# --------------------------------------------------
# CLOUDWATCH ALARMS PARA CACHE
# --------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "redis_cpu" {
  alarm_name          = "${local.prefijo}-redis-cpu-alta"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = 80

  dimensions = {
    CacheClusterId = aws_elasticache_cluster.redis_simple.cluster_id
  }

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "redis_memoria" {
  alarm_name          = "${local.prefijo}-redis-memoria-baja"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "FreeableMemory"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = 52428800  # 50 MB (alerta si queda poco)

  dimensions = {
    CacheClusterId = aws_elasticache_cluster.redis_simple.cluster_id
  }

  tags = local.tags
}

# ===========================================================
# OUTPUTS
# ===========================================================
output "redis_simple_endpoint" {
  description = "Endpoint del Redis standalone"
  value       = aws_elasticache_cluster.redis_simple.cache_nodes
}

output "redis_ha_endpoint" {
  description = "Endpoint del Redis HA (replication group)"
  value       = aws_elasticache_replication_group.redis_ha.primary_endpoint_address
}

output "redis_ha_reader_endpoint" {
  description = "Endpoint para lecturas del Redis HA"
  value       = aws_elasticache_replication_group.redis_ha.reader_endpoint_address
}

output "memcached_endpoint" {
  description = "Endpoint del cluster Memcached"
  value       = aws_elasticache_cluster.memcached.configuration_endpoint
}

output "caches_por_servicio" {
  value = { for k, c in aws_elasticache_cluster.por_servicio : k => {
    id     = c.cluster_id
    engine = c.engine
    nodos  = c.num_cache_nodes
  }}
}

output "comparativa_redis_vs_memcached" {
  value = <<-EOF

    ╔═══════════════════╦═════════════════════╦═══════════════════════╗
    ║ Característica     ║ Redis               ║ Memcached             ║
    ╠═══════════════════╬═════════════════════╬═══════════════════════╣
    ║ Persistencia       ║ ✅ Sí               ║ ❌ No                 ║
    ║ Replicación        ║ ✅ Primary-Replica  ║ ❌ No                 ║
    ║ Failover auto      ║ ✅ Sí               ║ ❌ No                 ║
    ║ Estructuras datos  ║ ✅ Listas, Sets,    ║ ❌ Solo key-value     ║
    ║                    ║    Hashes, Sorted   ║                       ║
    ║ Pub/Sub            ║ ✅ Sí               ║ ❌ No                 ║
    ║ Multi-thread       ║ ❌ Single-thread    ║ ✅ Multi-thread       ║
    ║ Uso ideal          ║ Sesiones, rankings, ║ Cache simple de       ║
    ║                    ║ real-time, pub/sub  ║ queries DB, objetos   ║
    ╚═══════════════════╩═════════════════════╩═══════════════════════╝

    PATRONES DE CACHE:
    • Cache-Aside: App lee cache, si no está, lee DB y guarda en cache
    • Read-Through: Cache busca en DB automáticamente si no tiene el dato
    • Write-Through: Escribir en cache y DB simultáneamente
    • Write-Behind: Escribir en cache, luego async a DB
    • TTL (Time To Live): Datos expiran automáticamente

  EOF
}

# --------------------------------------------------
# EJERCICIOS PROPUESTOS:
# --------------------------------------------------
# 1. Agrega un cache "carrito-compras" al mapa caches_por_servicio
#    usando Redis con 1 nodo cache.t3.medium.
#
# 2. Cambia la política de evicción del Redis a "volatile-lru"
#    (solo eliminar keys con TTL cuando se llena la memoria).
#
# 3. Agrega una alarma para "CacheHitRate" < 80%
#    (tasa de aciertos del cache baja).
#
# 4. Crea un SNS topic para recibir alertas de cache.
#
# 5. Escala verticalmente: cambia el node_type del Redis HA
#    de cache.t3.micro a cache.t3.medium.
#    ¿Terraform recrea el cluster o lo modifica in-place?
#
# 6. Investiga: ¿Qué pasa si agregas una réplica más al
#    replication group (num_cache_clusters = 4)?
