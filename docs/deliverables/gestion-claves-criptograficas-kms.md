# Gestión de Claves Criptográficas - AWS KMS en la Landing Zone

## 1. Resumen Ejecutivo

La Landing Zone implementa un modelo de cifrado en múltiples capas utilizando **AWS Key Management Service (KMS)** como mecanismo central para la gestión de claves criptográficas. El enfoque combina:

1. **Claves KMS gestionadas por AWS (AWS Managed Keys)** — creadas y rotadas automáticamente por AWS para servicios específicos
2. **Claves KMS gestionadas por el LZA (Customer Managed Keys)** — creadas por el Landing Zone Accelerator para cifrado de recursos de infraestructura
3. **Controles preventivos (SCPs)** — que obligan el uso de cifrado en servicios de almacenamiento
4. **Controles detectivos (AWS Config Rules)** — que verifican el cumplimiento de cifrado

---

## 2. Arquitectura de Cifrado

```
┌─────────────────────────────────────────────────────────────────────┐
│                    AWS Key Management Service (KMS)                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────────────┐    ┌──────────────────────────────────┐   │
│  │  AWS Managed Keys   │    │  LZA Customer Managed Keys (CMK) │   │
│  │  (aws/ebs, aws/s3,  │    │  (AWSAccelerator-InstallerKey,   │   │
│  │   aws/rds, etc.)    │    │   AWSAccelerator-Key, etc.)      │   │
│  └─────────────────────┘    └──────────────────────────────────┘   │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│  Controles Preventivos (SCPs)          │  Controles Detectivos      │
│  • Deny EFS sin cifrado               │  • Config Rules            │
│  • Deny RDS sin cifrado               │  • Security Hub Standards  │
│  • Deny RDS Cluster sin cifrado       │  • Control Tower Controls  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. Claves KMS Creadas por el Landing Zone Accelerator

El LZA crea automáticamente las siguientes claves Customer Managed Keys (CMK) en cada cuenta:

| Clave | Propósito | Rotación | Alcance |
|-------|-----------|----------|---------|
| **AWSAccelerator-InstallerKey** | Cifrado de artefactos del instalador LZA | Automática (anual) | Cuenta Management |
| **AWSAccelerator-Key** | Cifrado general de recursos LZA (S3 buckets de logs, CloudWatch Logs, SNS, etc.) | Automática (anual) | Todas las cuentas |
| **AWSAccelerator-EbsKey** | Cifrado por defecto de volúmenes EBS | Automática (anual) | Todas las cuentas (excepto Management) |

### 3.1 Cifrado de EBS por Defecto

```yaml
ebsDefaultVolumeEncryption:
  enable: true  # Habilitado en todas las regiones
  excludeRegions: []
```

**Efecto:** Todos los volúmenes EBS creados en cualquier cuenta se cifran automáticamente con la clave KMS del LZA sin intervención del usuario.

---

## 4. Controles Preventivos de Cifrado (SCPs)

Las Service Control Policies imponen cifrado obligatorio a nivel organizacional:

### 4.1 Amazon EFS (Elastic File System)

| Control | Efecto |
|---------|--------|
| **GREFS** | DENIEGA la creación de sistemas de archivos EFS sin cifrado habilitado |

```json
{
  "Sid": "GREFS",
  "Effect": "Deny",
  "Action": "elasticfilesystem:CreateFileSystem",
  "Condition": {
    "Bool": { "elasticfilesystem:Encrypted": "false" }
  }
}
```

### 4.2 Amazon RDS (Instancias)

| Control | Efecto |
|---------|--------|
| **GRRDS1** | DENIEGA la creación de instancias RDS (no Aurora) sin cifrado de almacenamiento |

```json
{
  "Sid": "GRRDS1",
  "Effect": "Deny",
  "Action": "rds:CreateDBInstance",
  "Condition": {
    "Bool": { "rds:StorageEncrypted": "false" }
  }
}
```

### 4.3 Amazon Aurora (Clusters)

| Control | Efecto |
|---------|--------|
| **GRRDS2** | DENIEGA la creación de clusters Aurora sin cifrado de almacenamiento |

```json
{
  "Sid": "GRRDS2",
  "Effect": "Deny",
  "Action": "rds:CreateDBCluster",
  "Condition": {
    "Bool": { "rds:StorageEncrypted": "false" }
  }
}
```

### 4.4 Alcance de los Controles Preventivos

| SCP | Cuentas/OUs donde aplica |
|-----|--------------------------|
| AWSAccelerator-Core-Workloads-Guardrails-1 | Workloads/Dev, Workloads/Test, Workloads/Prod |
| AWSAccelerator-Core-Sandbox-Guardrails-1 | Workloads/Sandbox |
| AWSAccelerator-Security-Guardrails-1 | Audit, LogArchive |
| AWSAccelerator-Infrastructure-Guardrails-1 | Network, Perimeter, SharedServices |

---

## 5. Controles Detectivos de Cifrado (AWS Config Rules)

Las siguientes reglas de AWS Config monitorean continuamente el cumplimiento de cifrado:

| Regla | Identificador | Qué Verifica |
|-------|---------------|--------------|
| dynamodb-table-encrypted-kms | DYNAMODB_TABLE_ENCRYPTED_KMS | Tablas DynamoDB cifradas con KMS |
| sagemaker-endpoint-configuration-kms-key-configured | SAGEMAKER_ENDPOINT_CONFIGURATION_KMS_KEY_CONFIGURED | Endpoints de SageMaker con clave KMS |
| sagemaker-notebook-instance-kms-key-configured | SAGEMAKER_NOTEBOOK_INSTANCE_KMS_KEY_CONFIGURED | Notebooks de SageMaker con clave KMS |
| secretsmanager-using-cmk | SECRETSMANAGER_USING_CMK | Secrets Manager usando CMK (no default) |
| codebuild-project-artifact-encryption | CODEBUILD_PROJECT_ARTIFACT_ENCRYPTION | Artefactos de CodeBuild cifrados |
| api-gw-cache-enabled-and-encrypted | API_GW_CACHE_ENABLED_AND_ENCRYPTED | Cache de API Gateway cifrado |
| cloudwatch-log-group-encrypted | CLOUDWATCH_LOG_GROUP_ENCRYPTED | CloudWatch Log Groups cifrados con KMS |
| backup-recovery-point-encrypted | BACKUP_RECOVERY_POINT_ENCRYPTED | Puntos de recuperación de Backup cifrados |

**Alcance:** Todas las cuentas en la organización (Root OU).

---

## 6. Control Tower Controls (Controles Proactivos)

| Control | Identificador | Qué Verifica |
|---------|---------------|--------------|
| CONFIG.LOGS.DT.1 | 497wrm2xnk1wxlf4obrdo7mej | CloudWatch Log Groups cifrados con KMS |
| CONFIG.SAGEMAKER.DT.3 | 3b7ib9mi87kcw90atgx2nboax | SageMaker notebooks con clave KMS |

**Alcance:** Todas las OUs (Security, Infrastructure, Workloads, Sandbox, Dev, Test, Prod).

---

## 7. Security Hub Standards (Verificación de Cifrado)

Los siguientes estándares de Security Hub incluyen controles de cifrado:

| Estándar | Estado | Alcance |
|----------|--------|---------|
| AWS Foundational Security Best Practices v1.0.0 | ✅ Habilitado | Root (todas las cuentas) |
| NIST SP 800-53 Rev. 5 | ✅ Habilitado | Root (todas las cuentas) |
| CIS AWS Foundations Benchmark v3.0.0 | ✅ Habilitado | Root (todas las cuentas) |

Estos estándares incluyen verificaciones automáticas de cifrado para: S3, EBS, RDS, EFS, Redshift, SQS, SNS, CloudTrail, entre otros.

---

## 8. VPC Endpoint para KMS

Se ha configurado un VPC Endpoint para el servicio KMS, permitiendo que las instancias en VPCs privadas accedan al servicio de KMS sin tráfico por internet:

```yaml
interfaceEndpoints:
  endpoints:
    - service: kms
```

**Beneficio:** Las operaciones criptográficas (cifrado/descifrado) se realizan a través de la red privada de AWS, sin exposición a internet.

---

## 9. Resumen de Servicios con Cifrado Obligatorio

| Servicio | Mecanismo de Enforcement | Tipo de Clave |
|----------|--------------------------|---------------|
| **EBS** | Cifrado por defecto habilitado | CMK del LZA (automático) |
| **EFS** | SCP - Deny sin cifrado | KMS (usuario debe especificar) |
| **RDS/Aurora** | SCP - Deny sin cifrado | KMS (usuario debe especificar) |
| **S3 (buckets LZA)** | Configuración LZA | CMK del LZA |
| **CloudWatch Logs** | Config Rule + Control Tower | KMS (verificación) |
| **DynamoDB** | Config Rule | KMS (verificación) |
| **Secrets Manager** | Config Rule | CMK (verificación) |
| **SageMaker** | Config Rule + Control Tower | KMS (verificación) |
| **Backup Recovery Points** | Config Rule | KMS (verificación) |
| **CodeBuild Artifacts** | Config Rule | KMS (verificación) |

---

## 10. Gestión del Ciclo de Vida de Claves

| Aspecto | Configuración |
|---------|---------------|
| **Creación** | Automática por LZA durante el despliegue |
| **Rotación** | Automática anual (habilitada por defecto en claves CMK del LZA) |
| **Acceso** | Controlado por Key Policy — solo roles del LZA y servicios autorizados |
| **Eliminación** | Protegida por SCPs — usuarios no pueden eliminar claves del LZA |
| **Auditoría** | CloudTrail registra todas las operaciones de KMS (Encrypt, Decrypt, GenerateDataKey, etc.) |

---

## 11. Evidencia de Configuración

### 11.1 Claves KMS en la consola
> *Adjuntar screenshot de: KMS → Customer managed keys (en cualquier cuenta)*
> *Ruta: AWS Console → KMS → Customer managed keys*

### 11.2 Cifrado EBS por defecto
> *Adjuntar screenshot de: EC2 → Settings → EBS encryption → Default encryption*
> *Ruta: AWS Console → EC2 → Account attributes → EBS encryption*

### 11.3 Config Rules de cifrado
> *Adjuntar screenshot de: AWS Config → Rules → filtrar por "encrypt" o "kms"*

### 11.4 Security Hub findings de cifrado
> *Adjuntar screenshot de: Security Hub → Standards → controles de cifrado*

---

*Documento preparado para: InsightGroup*  
*Fecha: Mayo 2025*  
*Landing Zone Accelerator v1.1.0 - Hub and Spoke*
