# Módulo 14 — Segmentación de Redes

## ¿Qué vas a aprender?

- Diseñar una arquitectura de red multi-VPC
- Qué es el VPC Peering y sus limitaciones
- Arquitectura de 3 capas (DMZ / Aplicación / Datos)
- Diferencia entre Security Groups y Network ACLs (NACLs)
- VPC Endpoints: acceso a servicios AWS sin salir a internet
- Cómo Terraform gestiona múltiples VPCs con sub-módulos locales

---

## Cómo ejecutar este módulo

```bash
docker-compose up -d
cd modulo-14-segmentacion-redes
terraform init
terraform apply -auto-approve
terraform output
terraform destroy
```

---

## Arquitectura diseñada

Este módulo crea **3 VPCs** separadas que colaboran mediante peering:

```
┌─────────────────────────────────────────────────┐
│  VPC Producción (10.100.0.0/16)                 │
│  ┌──────────────┐  ┌──────────────┐             │
│  │ Subnet DMZ   │  │ Subnet App   │  Subnet DB  │
│  │ 10.100.0/24  │  │ 10.100.1/24  │  10.100.2/24│
│  │ (ALB, WAF)   │  │ (App servers)│  (RDS)      │
│  └──────────────┘  └──────────────┘             │
└────────────────────────┬────────────────────────┘
                         │ VPC Peering
┌────────────────────────┴────────────────────────┐
│  VPC Backend (10.200.0.0/16)                    │
│  Microservicios internos, Lambda, EKS            │
└────────────────────────┬────────────────────────┘
                         │ VPC Peering
┌────────────────────────┴────────────────────────┐
│  VPC Management (10.50.0.0/16)                  │
│  Bastion hosts, CI/CD runners, monitoreo         │
└─────────────────────────────────────────────────┘
```

**¿Por qué separar en 3 VPCs?**

- **Aislamiento de seguridad**: Un compromiso en la VPC de producción no afecta automáticamente la VPC de management.
- **Cumplimiento regulatorio**: PCI-DSS, SOC2 y otras certificaciones requieren separación de entornos.
- **Control de acceso**: El tráfico entre VPCs es explícito y auditable.
- **Reducción del blast radius**: Si algo sale mal, el daño queda contenido en una VPC.

---

## Recurso 1: VPC Peering

El VPC Peering es un enlace directo entre dos VPCs. El tráfico va por la red privada de AWS, sin pasar por internet:

```hcl
# Peering entre Producción y Backend
resource "aws_vpc_peering_connection" "prod_backend" {
  vpc_id        = module.vpc_produccion.vpc_id
  peer_vpc_id   = module.vpc_backend.vpc_id
  auto_accept   = true   # Solo disponible en la misma cuenta AWS

  tags = merge(local.tags, { Name = "peer-prod-backend" })
}

# Peering entre Backend y Management
resource "aws_vpc_peering_connection" "backend_mgmt" {
  vpc_id        = module.vpc_backend.vpc_id
  peer_vpc_id   = module.vpc_management.vpc_id
  auto_accept   = true

  tags = merge(local.tags, { Name = "peer-backend-mgmt" })
}
```

### ⚠️ El peering NO es transitivo

Esta es la limitación más importante del VPC Peering:

```
VPC A ←→ VPC B ←→ VPC C

¿Puede A hablar con C? ❌ NO

Aunque A tiene peering con B y B tiene peering con C,
el tráfico de A NO puede llegar a C a través de B.

Para que A hable con C, necesitas:
  A ←→ C (peering directo)
  
Con 3 VPCs: necesitas 3 peerings (mesh completo)
Con 4 VPCs: necesitas 6 peerings
Con N VPCs: necesitas N*(N-1)/2 peerings
```

Para muchas VPCs, la alternativa es **AWS Transit Gateway** (un hub central que conecta todas las VPCs).

---

## Route Tables para peering

Crear el peering NO hace que funcione el tráfico automáticamente. Hay que agregar rutas en las route tables:

```hcl
# Desde Producción, el tráfico para 10.200.0.0/16 va por el peering
resource "aws_route" "prod_to_backend" {
  route_table_id            = module.vpc_produccion.route_table_id
  destination_cidr_block    = "10.200.0.0/16"   # CIDR de VPC Backend
  vpc_peering_connection_id = aws_vpc_peering_connection.prod_backend.id
}

# Desde Backend, el tráfico para 10.100.0.0/16 va por el peering
resource "aws_route" "backend_to_prod" {
  route_table_id            = module.vpc_backend.route_table_id
  destination_cidr_block    = "10.100.0.0/16"   # CIDR de VPC Producción
  vpc_peering_connection_id = aws_vpc_peering_connection.prod_backend.id
}
```

El peering es **bidireccional** pero las rutas son **unidireccionales**. Hay que definir la ruta en **ambas VPCs**.

---

## Arquitectura de 3 capas

Dentro de la VPC de Producción, se implementa una arquitectura de 3 capas:

```
Internet
    │
    ▼
┌─────────────────┐
│  Subnet DMZ      │  10.100.0.0/24 (pública)
│  (ALB, WAF)      │
└────────┬────────┘
         │ Solo puerto 8080 y 443
         ▼
┌─────────────────┐
│  Subnet App      │  10.100.1.0/24 (privada)
│  (EC2, ECS)      │
└────────┬────────┘
         │ Solo puerto 5432 y 3306
         ▼
┌─────────────────┐
│  Subnet Data     │  10.100.2.0/24 (privada)
│  (RDS, ElastiCache) │
└─────────────────┘
```

Cada capa solo puede comunicarse con la adyacente. La capa de datos nunca tiene acceso directo desde internet.

---

## Security Groups vs Network ACLs (NACLs)

Tanto los Security Groups como las NACLs controlan el tráfico, pero actúan a diferentes niveles:

| | Security Groups | NACLs |
|---|---|---|
| **Nivel** | Instancia (ENI) | Subnet |
| **Estado** | Stateful ✅ | Stateless ❌ |
| **Reglas** | Solo ALLOW | ALLOW y DENY |
| **Evaluación** | Todas las reglas | Por número (orden) |
| **Scope** | Por recurso | Toda una subnet |

**Stateful vs Stateless:**

```
# Security Group (stateful):
Si permites tráfico entrante en puerto 80,
la respuesta de salida se permite automáticamente.
No necesitas regla de salida para las respuestas.

# NACL (stateless):
Si permites tráfico entrante en puerto 80,
DEBES agregar también una regla para permite la salida
en los puertos efímeros (1024-65535).
```

---

## Network ACLs en Terraform

```hcl
resource "aws_network_acl" "dmz" {
  vpc_id     = aws_vpc.produccion.id
  subnet_ids = [aws_subnet.dmz.id]

  # Tráfico ENTRANTE (ingress)
  ingress {
    rule_no    = 100         # Menor número = mayor prioridad
    action     = "allow"
    protocol   = "tcp"
    from_port  = 443
    to_port    = 443
    cidr_block = "0.0.0.0/0"   # HTTPS desde cualquier IP
  }

  ingress {
    rule_no    = 110
    action     = "allow"
    protocol   = "tcp"
    from_port  = 80
    to_port    = 80
    cidr_block = "0.0.0.0/0"   # HTTP desde cualquier IP
  }

  ingress {
    rule_no    = 120
    action     = "allow"
    protocol   = "tcp"
    from_port  = 1024           # Puertos efímeros (respuestas)
    to_port    = 65535
    cidr_block = "0.0.0.0/0"
  }

  ingress {
    rule_no    = 32766
    action     = "deny"
    protocol   = "-1"           # Todos los protocolos
    from_port  = 0
    to_port    = 0
    cidr_block = "0.0.0.0/0"   # Bloquear todo lo demás
  }

  # Tráfico SALIENTE (egress)
  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    from_port  = 8080           # Al app server
    to_port    = 8080
    cidr_block = "10.100.1.0/24"
  }
  # ...
}
```

Las reglas se evalúan en orden ascendente de `rule_no`. La primera que coincide, se aplica.

---

## VPC Endpoint

Normalmente, para que una instancia privada acceda a S3, necesita salir a internet (via NAT Gateway). Con un VPC Endpoint, **el tráfico nunca sale de la red de AWS**:

```hcl
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.produccion.id
  service_name = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"   # Para S3 y DynamoDB usa Gateway

  route_table_ids = [aws_route_table.privada.id]

  tags = merge(local.tags, { Name = "vpc-endpoint-s3" })
}
```

**Beneficios del VPC Endpoint:**

- **Seguridad**: El tráfico no sale a internet
- **Costo**: No paga NAT Gateway para tráfico a S3 (ahorro significativo)
- **Rendimiento**: Menor latencia al acceder a servicios AWS

---

## Outputs de conectividad

```hcl
output "vpc_ids" {
  value = {
    produccion = module.vpc_produccion.vpc_id
    backend    = module.vpc_backend.vpc_id
    management = module.vpc_management.vpc_id
  }
}

output "peering_connections" {
  value = {
    prod_backend  = aws_vpc_peering_connection.prod_backend.id
    backend_mgmt  = aws_vpc_peering_connection.backend_mgmt.id
  }
}

output "subnet_ids" {
  value = {
    dmz  = module.vpc_produccion.subnet_dmz_id
    app  = module.vpc_produccion.subnet_app_id
    data = module.vpc_produccion.subnet_data_id
  }
}
```

---

## Ejercicios propuestos

1. Agrega el peering directo entre `vpc_produccion` y `vpc_management`. Qué rutas necesitas agregar en ambas VPCs.

2. Crea una NACL para la subnet `data` que solo permita tráfico en puerto 5432 (PostgreSQL) desde la subnet `app`.

3. Explica por qué con 3 VPCs en mesh completo necesitas exactamente 3 peering connections.

4. Agrega un VPC Endpoint para DynamoDB en la VPC de producción (tipo Gateway, igual que S3).

5. ¿Qué pasaría si pones `rule_no = 32766 / action = "deny" / cidr_block = "203.0.113.0/24"` en la NACL del DMZ? ¿Qué efecto tiene antes vs después del allow general?
