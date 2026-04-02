# Módulo 08 — VPC · Redes virtuales en la nube

## ¿Qué vas a aprender?

- Qué es una VPC y para qué sirve
- Diferencia entre subnets públicas y privadas
- Internet Gateway (IGW) y NAT Gateway
- Route Tables: cómo fluye el tráfico dentro de la VPC
- Security Groups: firewalls a nivel de instancia
- Calcular rangos de IPs con `cidrsubnet()`
- Crear subnets dinámicamente con `for_each` y `for` en locals
- Usar `values()` para obtener los valores de un mapa
- Dependencias explícitas con `depends_on`

---

## Cómo ejecutar este módulo

```bash
docker-compose up -d
cd modulo-08-vpc
terraform init
terraform apply -auto-approve
terraform output
terraform destroy
```

---

## Concepto previo — ¿Qué es una VPC?

Sin VPC, todos tus recursos de AWS estarían en la misma red sin aislamiento. La VPC es tu red privada virtual en la nube, completamente aislada de las demás cuentas.

```
Tu cuenta AWS
└── VPC (10.0.0.0/16 — tu red privada)
    ├── Subnet pública (10.0.0.0/24) — accede a Internet
    │   └── Servidor web
    │
    ├── Subnet pública (10.0.1.0/24)
    │   └── Load Balancer
    │
    ├── Subnet privada (10.0.100.0/24) — sin acceso directo a Internet
    │   └── Base de datos
    │
    └── Subnet privada (10.0.101.0/24)
        └── Servicio interno
```

---

## Notación CIDR — ¿Qué significa `10.0.0.0/16`?

CIDR define rangos de IPs. El número después de `/` dice cuántos bits están fijos (el prefijo de la red):

```
10.0.0.0/16  →  65.536 IPs disponibles (10.0.0.0 hasta 10.0.255.255)
10.0.0.0/24  →  256 IPs disponibles    (10.0.0.0 hasta 10.0.0.255)
10.0.0.0/28  →  16 IPs disponibles     (10.0.0.0 hasta 10.0.0.15)
```

Cuanto mayor el número después de `/`, menor el rango y menos IPs disponibles.

---

## La función `cidrsubnet()` — Dividir rangos automáticamente

```hcl
locals {
  subnets_publicas = {
    for idx, az in var.zonas_disponibilidad :
    az => cidrsubnet(var.vpc_cidr, 8, idx)
  }
  # Si vpc_cidr = "10.0.0.0/16":
  # "us-east-1a" => cidrsubnet("10.0.0.0/16", 8, 0) = "10.0.0.0/24"
  # "us-east-1b" => cidrsubnet("10.0.0.0/16", 8, 1) = "10.0.1.0/24"
  # "us-east-1c" => cidrsubnet("10.0.0.0/16", 8, 2) = "10.0.2.0/24"

  subnets_privadas = {
    for idx, az in var.zonas_disponibilidad :
    az => cidrsubnet(var.vpc_cidr, 8, idx + 100)
  }
  # "us-east-1a" => "10.0.100.0/24"
  # "us-east-1b" => "10.0.101.0/24"
  # "us-east-1c" => "10.0.102.0/24"
}
```

**Firma de `cidrsubnet(prefix, newbits, netnum)`:**

| Argumento | Qué hace |
|-----------|----------|
| `prefix` | El CIDR base (`"10.0.0.0/16"`) |
| `newbits` | Bits adicionales al prefijo. Con `8` nuevos bits: `/16 + 8 = /24` |
| `netnum` | El número de la subred (0, 1, 2...). Cada número = una subnet diferente |

En vez de hardcodear cada CIDR manualmente, `cidrsubnet` los calcula automáticamente y garantiza que no se superpongan.

---

## Recurso 1 — VPC

```hcl
resource "aws_vpc" "principal" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, {
    Name = "${local.prefijo}-vpc"
  })
}
```

- `cidr_block` → El rango de IPs de toda tu red privada
- `enable_dns_support = true` → Los recursos pueden resolverse por DNS dentro de la VPC
- `enable_dns_hostnames = true` → Las instancias EC2 reciben nombres DNS automáticamente

---

## Recurso 2 — Internet Gateway

```hcl
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.principal.id

  tags = merge(local.tags, {
    Name = "${local.prefijo}-igw"
  })
}
```

El IGW es la "puerta de salida" a Internet. Sin él, ningún recurso puede comunicarse con el exterior aunque esté en una subnet pública.

```
Internet  ←→  Internet Gateway  ←→  Subnet pública  ←→  Recursos
```

---

## Recurso 3 — Subnets públicas con `for_each`

```hcl
resource "aws_subnet" "publicas" {
  for_each = local.subnets_publicas

  vpc_id                  = aws_vpc.principal.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name = "${local.prefijo}-publica-${each.key}"
    tipo = "publica"
  })
}
```

- `for_each = local.subnets_publicas` → Crea una subnet por cada zona de disponibilidad
- `availability_zone = each.key` → `each.key` es el AZ (ejemplo: `"us-east-1a"`)
- `cidr_block = each.value` → `each.value` es el CIDR calculado
- `map_public_ip_on_launch = true` → Los recursos lanzados aquí reciben IP pública automáticamente

---

## Recurso 4 — NAT Gateway

```hcl
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.tags, {
    Name = "${local.prefijo}-nat-eip"
  })

  depends_on = [aws_internet_gateway.igw]
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = values(aws_subnet.publicas)[0].id

  tags = merge(local.tags, {
    Name = "${local.prefijo}-nat-gw"
  })

  depends_on = [aws_internet_gateway.igw]
}
```

**¿Por qué necesito un NAT Gateway?**

Las instancias en subnets **privadas** no tienen IP pública, por lo que no pueden acceder a Internet directamente. Pero a veces necesitan salir a Internet (para descargar paquetes, llamar APIs externas, etc.).

```
Subnet privada → NAT Gateway (en subnet pública) → Internet Gateway → Internet
                 (tiene IP pública fija = Elastic IP)
Las respuestas vuelven por el mismo camino inverso
```

**`aws_eip`** (Elastic IP): una IP pública fija que reservas para tu cuenta. El NAT Gateway la usa para salir a Internet.

**`values(aws_subnet.publicas)[0].id`**: extrae todos los valores del mapa de subnets públicas como lista y toma el primero (`[0]`). El NAT Gateway vive en una sola subnet pública.

---

## Recurso 5 — Route Tables (tablas de enrutamiento)

Las route tables definen a dónde va el tráfico según el destino.

```hcl
# Route Table PÚBLICA: el tráfico a Internet va por el IGW
resource "aws_route_table" "publica" {
  vpc_id = aws_vpc.principal.id

  route {
    cidr_block = "0.0.0.0/0"         # Todo el tráfico externo
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = merge(local.tags, {
    Name = "${local.prefijo}-rt-publica"
  })
}

# Route Table PRIVADA: el tráfico a Internet va por el NAT Gateway
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
```

**`0.0.0.0/0`**: significa "cualquier IP que no esté en la VPC". Es la ruta por defecto para tráfico a Internet.

**Diferencia de las dos route tables:**

| Route table | Destino `0.0.0.0/0` | Resultado |
|---|---|---|
| Pública | Internet Gateway | Los recursos pueden hablar con Internet **y ser contactados desde Internet** |
| Privada | NAT Gateway | Los recursos pueden hablar con Internet **pero NO ser contactados desde Internet** |

---

## Asociar subnets a route tables

```hcl
resource "aws_route_table_association" "publicas" {
  for_each = aws_subnet.publicas

  subnet_id      = each.value.id
  route_table_id = aws_route_table.publica.id
}

resource "aws_route_table_association" "privadas" {
  for_each = aws_subnet.privadas

  subnet_id      = each.value.id
  route_table_id = aws_route_table.privada.id
}
```

Sin esta asociación, las subnets usan la route table por defecto de la VPC (que no tiene ruta a Internet).

---

## Recurso 6 — Security Groups

Los Security Groups son firewalls virtuales que controlan el tráfico **por instancia**.

```hcl
# SG para servidores web
resource "aws_security_group" "web" {
  name   = "${local.prefijo}-sg-web"
  vpc_id = aws_vpc.principal.id

  # ENTRAR: permite HTTP y HTTPS desde cualquier IP
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SALIR: permite todo
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"     # -1 = todos los protocolos
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# SG para base de datos (solo acepta tráfico DEL SG web)
resource "aws_security_group" "db" {
  name   = "${local.prefijo}-sg-db"
  vpc_id = aws_vpc.principal.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]  # Solo desde el SG web
  }
}
```

**Reglas clave:**

| Campo | Significado |
|-------|-------------|
| `ingress` | Tráfico **entrante** (conexiones que llegan) |
| `egress` | Tráfico **saliente** (conexiones que salen) |
| `from_port` / `to_port` | Rango de puertos (para un solo puerto: `from == to`) |
| `protocol = "tcp"` | TCP. También: `"udp"`, `"icmp"`, `"-1"` (todos) |
| `cidr_blocks` | Restricción por IP. `["0.0.0.0/0"]` = cualquier IP |
| `security_groups` | Restricción por otro SG. Solo acepta tráfico de instancias con ese SG |

**La arquitectura de capas en acción:**

```
Internet (0.0.0.0/0)
    ↓ HTTP/HTTPS
Servidor web (sg-web)
    ↓ Solo PostgreSQL (5432)
Base de datos (sg-db)  ← no acepta conexiones directas de Internet
```

---

## Outputs

```hcl
output "vpc_id" {
  value = aws_vpc.principal.id
}

output "subnets_publicas" {
  value = { for az, subnet in aws_subnet.publicas : az => subnet.id }
}

output "subnets_privadas" {
  value = { for az, subnet in aws_subnet.privadas : az => subnet.id }
}
```

---

## Resumen de la arquitectura creada

```
VPC: 10.0.0.0/16
│
├── Internet Gateway
│
├── Subnet pública us-east-1a (10.0.0.0/24)   ─┐
├── Subnet pública us-east-1b (10.0.1.0/24)   ─┤ → Route table pública → IGW
├── Subnet pública us-east-1c (10.0.2.0/24)   ─┘
│       └── NAT Gateway (con Elastic IP)
│
├── Subnet privada us-east-1a (10.0.100.0/24)  ─┐
├── Subnet privada us-east-1b (10.0.101.0/24)  ─┤ → Route table privada → NAT GW
└── Subnet privada us-east-1c (10.0.102.0/24)  ─┘
```

---

## Ejercicios propuestos

1. Añade una cuarta zona `"us-east-1d"` a `zonas_disponibilidad`. ¿Cuántas subnets nuevas crea `terraform plan`?

2. Cambia el CIDR de la VPC a `"172.16.0.0/16"` y ejecuta `terraform plan`. ¿Qué pasa con todos los recursos?

3. Agrega una regla al `aws_security_group.web` para aceptar SSH (puerto 22) solo desde tu IP (`"203.0.113.1/32"`).

4. Crea un nuevo Security Group `app` que acepte tráfico en el puerto `8080` solo desde el SG `web`. Conéctalo entre `web` y `db`.

5. Usa `terraform output subnets_publicas` y examina el mapa retornado con las IDs de las subnets.
