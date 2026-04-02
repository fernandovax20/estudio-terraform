# Módulo 13 — Cache

## ¿Qué vas a aprender?

- Qué es ElastiCache y cuándo usarlo
- Diferencias entre Redis y Memcached
- Subnet Groups: dónde vive el cache en la red
- Parameter Groups: configurar el comportamiento del motor
- Crear un cluster Redis con replicación
- Crear un cluster Memcached
- Outputs para conectar aplicaciones al cache

---

## Cómo ejecutar este módulo

```bash
docker-compose up -d
cd modulo-13-cache
terraform init
terraform apply -auto-approve
terraform output
terraform destroy
```

---

## ¿Qué es y para qué sirve el cache?

Una base de datos tarda ~10-50ms en responder una consulta. Un cache tarda ~0.1ms. Si tu aplicación hace las mismas consultas repetidamente, cachear el resultado es 100-500x más rápido.

**Casos de uso típicos:**

| Caso | Cómo se usa el cache |
|------|---------------------|
| Sesiones de usuario | Guardar sesión por token, TTL = duración de sesión |
| Resultados de queries | Cachear por N segundos consultas costosas |
| Rate limiting | Contar peticiones por IP en una ventana de tiempo |
| Pub/Sub en tiempo real | Redis como bus de mensajes ligero |
| Resultados de API externa | Cachear para no exceder rate limits |

---

## Redis vs Memcached

| Característica | Redis | Memcached |
|----------------|-------|-----------|
| **Tipos de datos** | Strings, listas, sets, hashes, sorted sets, streams | Solo strings |
| **Persistencia** | Sí (RDB, AOF) | No |
| **Replicación** | Sí (primario + réplicas) | No nativa |
| **Failover automático** | Sí (con Multi-AZ) | No |
| **Lua scripting** | Sí | No |
| **Uso recomendado** | Sesiones, leaderboards, pub/sub, colas | Cache simple de objetos |
| **Multi-hilo** | No (single-threaded) | Sí |

**Regla general:**
- Necesitas más que solo cache → **Redis**
- Solo necesitas cache de objetos con máxima velocidad → **Memcached**

---

## Recurso 1: Subnet Group

ElastiCache necesita saber en qué subnets de tu VPC puede crear los nodos:

```hcl
resource "aws_elasticache_subnet_group" "redis" {
  name       = "redis-subnet-group-${var.entorno}"
  subnet_ids = var.private_subnet_ids   # Siempre subnets privadas, nunca públicas

  tags = local.tags
}
```

Los nodos de cache deben estar en **subnets privadas**. Solo las aplicaciones dentro de la VPC deben poder conectarse. Exponer un cache a internet es un riesgo de seguridad grave.

---

## Recurso 2: Parameter Group

El Parameter Group es como un archivo de configuración del motor Redis/Memcached:

```hcl
resource "aws_elasticache_parameter_group" "redis" {
  family = "redis7"   # La familia debe coincidir con la versión del cluster
  name   = "redis-params-${var.entorno}"

  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
    # allkeys-lru: cuando el cache está lleno, elimina las claves
    # menos usadas recientemente (LRU = Least Recently Used)
  }

  parameter {
    name  = "timeout"
    value = "300"
    # Desconectar clientes inactivos después de 300 segundos
  }

  parameter {
    name  = "notify-keyspace-events"
    value = "Ex"
    # E = Keyevent events, x = Expired events
    # Notifica cuando las claves expiran (útil para invalidación de cache)
  }
}
```

**Políticas de evicción (`maxmemory-policy`):**

| Política | Comportamiento |
|----------|---------------|
| `noeviction` | Rechaza escrituras cuando el cache está lleno. Error al escribir |
| `allkeys-lru` | Elimina cualquier clave por LRU (recomendado para cache general) |
| `volatile-lru` | Elimina solo claves con TTL por LRU |
| `allkeys-random` | Elimina claves aleatoriamente |
| `volatile-ttl` | Elimina la clave con el TTL más corto primero |

---

## Recurso 3: Redis Replication Group

```hcl
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "redis-${var.entorno}"
  description          = "Cluster Redis para ${var.entorno}"

  node_type            = var.node_type          # e.g. "cache.t3.micro"
  num_cache_clusters   = var.num_cache_clusters # 1 primario + N réplicas

  parameter_group_name = aws_elasticache_parameter_group.redis.name
  subnet_group_name    = aws_elasticache_subnet_group.redis.name

  engine_version       = "7.0"
  port                 = 6379   # Puerto estándar de Redis

  automatic_failover_enabled = var.multi_az   # Failover automático si el primario falla
  multi_az_enabled           = var.multi_az   # Distribuir en múltiples zonas

  at_rest_encryption_enabled  = true   # Cifrar los datos en disco
  transit_encryption_enabled  = true   # Cifrar los datos en tránsito (TLS)

  auth_token = var.redis_auth_token   # Contraseña de acceso (requerida con TLS)

  maintenance_window           = "sun:05:00-sun:06:00"
  snapshot_window              = "03:00-05:00"
  snapshot_retention_limit     = 7   # Guardar snapshots 7 días

  tags = local.tags
}
```

**`num_cache_clusters`:**
- `1`: Solo nodo primario. Sin redundancia. Para dev.
- `2`: Un primario + una réplica. Si el primario falla, la réplica asume.
- `3+`: Un primario + más réplicas. A más réplicas, más lecturas se distribuyen.

**Endpoints resultantes:**
- `primary_endpoint_address`: Para escrituras (siempre apunta al primario)
- `reader_endpoint_address`: Para lecturas (distribuye entre réplicas)

Las aplicaciones bien diseñadas usan el reader endpoint para lecturas y el primary para escrituras.

---

## Recurso 4: Cluster Memcached

```hcl
resource "aws_elasticache_cluster" "memcached" {
  cluster_id           = "memcached-${var.entorno}"
  engine               = "memcached"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 3      # Número de nodos del cluster
  parameter_group_name = "default.memcached1.6"
  engine_version       = "1.6.17"
  port                 = 11211  # Puerto estándar de Memcached

  subnet_group_name    = aws_elasticache_subnet_group.memcached.name

  az_mode              = "cross-az"   # Distribuir nodos en diferentes AZs
}
```

Memcached distribuye las claves entre los nodos usando hash consistente. Tu cliente necesita conocer **todos** los nodos y calcular en qué nodo está cada clave.

**`configuration_endpoint`**: Un endpoint especial que devuelve la lista de todos los nodos al cliente para que pueda conectarse a todos.

---

## Outputs para las aplicaciones

```hcl
output "redis_primary_endpoint" {
  value = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "redis_reader_endpoint" {
  value = aws_elasticache_replication_group.redis.reader_endpoint_address
}

output "redis_port" {
  value = 6379
}

output "memcached_config_endpoint" {
  value = aws_elasticache_cluster.memcached.configuration_endpoint
}
```

Las aplicaciones usarán estos endpoints. Pasarlos vía variables de entorno o SSM Parameter Store:

```hcl
resource "aws_ssm_parameter" "redis_endpoint" {
  name  = "/${var.entorno}/redis/primary_endpoint"
  type  = "String"
  value = aws_elasticache_replication_group.redis.primary_endpoint_address
}
```

---

## Patrones de conexión

**Desde una aplicación Python (Redis):**

```python
import redis

r = redis.Redis(
    host=os.environ['REDIS_HOST'],
    port=6379,
    password=os.environ['REDIS_AUTH_TOKEN'],
    ssl=True,           # transit_encryption_enabled = true
    decode_responses=True
)

# Cache-aside pattern
def get_user(user_id):
    cached = r.get(f"user:{user_id}")
    if cached:
        return json.loads(cached)
    
    user = db.query(f"SELECT * FROM users WHERE id = {user_id}")
    r.setex(f"user:{user_id}", 300, json.dumps(user))  # TTL 5 minutos
    return user
```

---

## Tipos de nodos y costos

Los nodos de ElastiCache son similares a EC2 en nomenclatura:

```
cache.t3.micro    →  0.5 GB RAM   (dev/test)
cache.t3.small    →  1.37 GB RAM  (dev/test)
cache.t3.medium   →  3.09 GB RAM  (dev/test)
cache.r6g.large   → 13.07 GB RAM  (producción)
cache.r6g.xlarge  → 26.32 GB RAM  (producción)
```

Para producción, usa nodos de la familia `r` (memory-optimized), no `t` (burstable).

---

## Ejercicios propuestos

1. Cambia `num_cache_clusters` de `1` a `2` en el replication group. Ejecuta `terraform plan`. ¿Qué dice? ¿Crea una réplica nueva?

2. Añade un nuevo parámetro al Parameter Group: `activerehashing` con valor `yes`. ¿Qué hace este parámetro? (Consúltalo en la documentación de Redis).

3. Agrega a los outputs el `cluster_id` y la `engine_version` del cluster Memcached.

4. Crea un recurso `aws_ssm_parameter` que guarde el endpoint del Reader de Redis para ser consumido por aplicaciones.

5. Modifica `maintenance_window` a un horario de poca actividad para tu caso de uso. ¿Por qué importa la ventana de mantenimiento?
