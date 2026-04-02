# Módulo 16 — Backup y Disaster Recovery

## ¿Qué vas a aprender?

- Los conceptos RPO y RTO: cómo medir la resiliencia
- Las 4 estrategias de Disaster Recovery en AWS
- Configurar lifecycle policies en S3 para mover datos a storage más barato
- Versionado de S3 para recuperar objetos borrados
- Replicación cross-region de S3
- Point-in-Time Recovery (PITR) en DynamoDB
- Cómo automatizar toda la estrategia de backup con Terraform

---

## Cómo ejecutar este módulo

```bash
docker-compose up -d
cd modulo-16-backup-dr
terraform init
terraform apply -auto-approve
terraform output
terraform destroy
```

---

## RPO y RTO: los dos parámetros clave

Antes de configurar cualquier solución de backup, hay que entender qué se necesita:

**RPO (Recovery Point Objective):** ¿Cuántos datos puedo perder?

```
Último backup exitoso
        │
        │  ← Este es tu RPO (¿cuánto tiempo de datos puedes perder?)
        │
   Momento del desastre
```

Si tu RPO es 1 hora, significa que si el sistema falla a las 3:00pm, puedes restaurar desde las 2:00pm y perder 1 hora de datos.

**RTO (Recovery Time Objective):** ¿Cuánto tiempo puedo estar sin servicio?

```
Momento del desastre → [TIEMPO DE RECUPERACIÓN] → Sistema restaurado
                          │
                          └ Este tiempo debe ser ≤ RTO
```

| Ejemplo | RPO | RTO |
|---------|-----|-----|
| Red social (fotos) | 24 horas | 4 horas |
| E-Commerce | 1 hora | 30 minutos |
| Banco (transacciones) | 0 segundos | < 1 minuto |
| Hospital (historias clínicas) | 0 segundos | 0 segundos |

**RPO y RTO más estrictos = más caro.** La solución de backup debe ajustarse al negocio.

---

## Las 4 estrategias de DR en AWS

### Estrategia 1: Backup & Restore (el más barato)

```
Región principal → Backup periódico → Región secundaria

RPO: horas/días
RTO: horas
Costo: muy bajo (solo almacenamiento)
```

Restauras desde los backups cuando hay un desastre. El tiempo de recuperación es alto (montar toda la infraestructura desde cero).

### Estrategia 2: Pilot Light (el más común)

```
Región principal (ACTIVA)   →   Región secundaria (MÍNIMA)
  Todo funcionando               Solo la base de datos
                                 (el "piloto encendido")
```

Tienes una base de datos secundaria replicando en tiempo real. Cuando hay un desastre, "enciendes" el resto de la infraestructura en la región secundaria (tarda 10-30 minutos).

```
RPO: minutos (replicación continua)
RTO: 10-30 minutos
Costo: bajo (solo DB secundaria)
```

### Estrategia 3: Warm Standby

```
Región principal (ACTIVA, escala completa)
Región secundaria (ACTIVA, escala reducida)
  - 2 instancias en lugar de 20
  - Puede recibir tráfico inmediatamente
```

La región secundaria está funcionando pero más pequeña. Al hacer failover, simplemente escala las instancias. Sin downtime real.

```
RPO: segundos
RTO: minutos
Costo: moderado (infraestructura secundaria pequeña)
```

### Estrategia 4: Active-Active (la más cara y robusta)

```
Región principal (activa, recibiendo tráfico)
Región secundaria (activa, recibiendo tráfico)
  - Mismo tamaño
  - RDS Multi-Region, DynamoDB Global Tables
  - Route53 routea al más cercano / más sano
```

No hay "failover": siempre hay dos instancias procesando tráfico. Si una falla, la otra ya está manejando la mitad del tráfico y escala para el 100%.

```
RPO: 0 segundos (replicación síncrona/casi-síncrona)
RTO: 0 segundos (no hay failover, hay redundancia)
Costo: 2x (todo duplicado)
```

---

## Recurso 1: S3 con Versionado

```hcl
resource "aws_s3_bucket" "datos" {
  bucket = "backup-datos-${var.entorno}"
}

resource "aws_s3_bucket_versioning" "datos" {
  bucket = aws_s3_bucket.datos.id
  versioning_configuration {
    status = "Enabled"
  }
}
```

**¿Por qué el versionado?**

Sin versionado:
```
objeto: "informe.pdf" (v1) → sobrescribir → "informe.pdf" (v2)
Si alguien borra el archivo accidentalmente → perdido para siempre
```

Con versionado:
```
objeto: "informe.pdf" (v1) → sobrescribir → "informe.pdf" (v2, v1 guardada)
Si alguien borra el archivo → solo crea un "delete marker", la v1 sigue ahí
```

Para "restaurar" un objeto borrado, eliminas el delete marker. Para restaurar una versión anterior, eliminas las versiones más recientes.

---

## Recurso 2: Lifecycle Policies

Guardar datos siempre en S3 Standard es caro. Las lifecycle policies mueven automáticamente los datos a storage más barato según la antigüedad:

```hcl
resource "aws_s3_bucket_lifecycle_configuration" "datos" {
  bucket = aws_s3_bucket.datos.id

  rule {
    id     = "mover-a-bajo-costo"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
      # Después de 30 días → Infrequent Access
      # Precio: ~$0.0125/GB/mes (vs $0.023 Standard)
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
      # Después de 90 días → Glacier
      # Precio: ~$0.004/GB/mes
      # PERO: para recuperar datos hay un delay de minutos/horas
    }

    transition {
      days          = 180
      storage_class = "DEEP_ARCHIVE"
      # Después de 180 días → Glacier Deep Archive
      # Precio: ~$0.00099/GB/mes (el más barato)
      # PERO: para recuperar datos hay un delay de 12-48 horas
    }

    expiration {
      days = 365   # Eliminar objetos después de 1 año
    }

    # También limpiar versiones antiguas
    noncurrent_version_expiration {
      noncurrent_days = 90   # Borrar versiones antiguas después de 90 días
    }
  }
}
```

**Comparación de storage classes:**

| Clase | Costo/GB/mes | Latencia de acceso | Cuándo usar |
|-------|-------------|-------------------|-------------|
| Standard | $0.023 | milisegundos | Datos accedidos frecuentemente |
| Standard-IA | $0.0125 | milisegundos | Datos accedidos < 1 vez/mes |
| Glacier Instant | $0.004 | milisegundos | Backups que pueden restaurarse rápido |
| Glacier Flexible | $0.0036 | minutos/horas | Backups que se restauran ocasionalmente |
| Glacier Deep Archive | $0.00099 | 12-48 horas | Archivos históricos, cumplimiento legal |

---

## Recurso 3: Cross-Region Replication (CRR)

Para RPO cercano a cero en S3, la replicación cross-region copia cada objeto a otra región automáticamente:

```hcl
resource "aws_s3_bucket_replication_configuration" "datos" {
  bucket = aws_s3_bucket.datos.id
  role   = aws_iam_role.replication.arn

  rule {
    id     = "replicar-todo"
    status = "Enabled"

    destination {
      bucket        = aws_s3_bucket.datos_dr.arn
      storage_class = "STANDARD_IA"   # Guardar réplica en clase más barata
    }
  }
}
```

**Qué replicar:** Solo objetos nuevos a partir del momento en que se activa la replicación. Los objetos existentes no se replican automáticamente (necesitas S3 Batch Replication para eso).

**Replicación unidireccional vs bidireccional:** Por defecto es unidireccional (principal → DR). Para Active-Active necesitarías replicación bidireccional.

---

## Recurso 4: DynamoDB PITR

PITR (Point-in-Time Recovery) es como tener una "máquina del tiempo" para tu base de datos:

```hcl
resource "aws_dynamodb_table" "datos" {
  name         = "datos-${var.entorno}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true   # Activar PITR
    # DynamoDB guarda backups continuos de los últimos 35 días
  }

  tags = local.tags
}
```

Con PITR habilitado, puedes restaurar la tabla a **cualquier segundo** de los últimos 35 días:

```bash
# Restaurar tabla al estado que tenía hace exactamente 2 horas
aws dynamodb restore-table-to-point-in-time \
  --source-table-name datos-produccion \
  --target-table-name datos-produccion-restored \
  --restore-date-time "2024-01-15T14:30:00Z"
```

La restauración crea una **nueva tabla**. Tienes que migrar la aplicación a esa tabla o copiar los datos.

---

## Outputs para el runbook de DR

```hcl
output "runbook_recovery" {
  value = {
    rpo_objetivo_minutos  = 60
    rto_objetivo_minutos  = 30

    paso_1 = "Verificar el incident en PagerDuty / alertas"
    paso_2 = "Ejecutar: terraform workspace select dr-region"
    paso_3 = "Ejecutar: terraform apply -var='region=us-west-2'"
    paso_4 = "Verificar health checks del ALB"
    paso_5 = "Redirigir DNS a la región DR via Route53"
    paso_6 = "Notificar al equipo y a los usuarios"

    restaurar_tabla_dynamodb = join(" ", [
      "aws dynamodb restore-table-to-point-in-time",
      "--source-table-name ${aws_dynamodb_table.datos.name}",
      "--target-table-name ${aws_dynamodb_table.datos.name}-restored",
      "--use-latest-restorable-time"
    ])
  }
}
```

Documentar el proceso de recuperación en los outputs de Terraform asegura que está siempre junto a la infraestructura y actualizado.

---

## Ejercicios propuestos

1. Modifica la lifecycle policy para agregar una regla que expire objetos con el prefijo `"temp/"` después de 7 días.

2. ¿Qué RPO conseguirías con la replicación cross-region de S3? ¿Con PITR de DynamoDB?

3. Activa el versionado en el bucket S3 y luego crea un objeto, modifícalo, y "bórralo". Verifica con `aws s3api list-object-versions` que las versiones anteriores siguen ahí.

4. ¿Qué estrategia de DR escogerías para un blog personal? ¿Y para un sistema de pagos de un banco? Justifica en términos de RPO, RTO y costo.

5. Agrega un output que calcule el costo estimado de mantener 1 TB de datos durante 1 año pasando por todas las storage classes.
