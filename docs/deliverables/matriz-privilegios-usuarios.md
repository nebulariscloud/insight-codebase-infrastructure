# Matriz de Privilegios de Usuarios - Landing Zone Accelerator

## 1. Resumen Ejecutivo

Esta matriz documenta los privilegios, roles y políticas implementados en la Landing Zone para la organización AWS de InsightGroup. La configuración de IAM se gestiona de forma centralizada a través del Landing Zone Accelerator (LZA) con el prefijo `AWSAccelerator`.

---

## 2. Estructura Organizacional (Cuentas y OUs)

| Cuenta | OU | Descripción |
|--------|-----|-------------|
| Management | Root | Cuenta de gestión principal de la organización |
| LogArchive | Security | Almacenamiento centralizado de logs |
| Audit | Security | Cuenta de auditoría de seguridad |
| SharedServices | Infrastructure | Servicios compartidos |
| Network | Infrastructure | Gestión de red |
| Perimeter | Infrastructure | Perímetro de seguridad de red |

### Unidades Organizacionales (OUs)

- Root
- Security
- Infrastructure
- Suspended
- Workloads/Sandbox
- Workloads/Dev
- Workloads/Test
- Workloads/Prod

---

## 3. Roles IAM Implementados

### 3.1 AWSAccelerator-Backup-Role

| Atributo | Valor |
|----------|-------|
| **Nombre** | AWSAccelerator-Backup-Role |
| **Servicio que lo asume** | backup.amazonaws.com |
| **Políticas AWS Managed** | AWSBackupServiceRolePolicyForBackup, AWSBackupServiceRolePolicyForRestores |
| **Alcance de despliegue** | Todas las cuentas en Root (excepto Management) |
| **Propósito** | Ejecutar planes de respaldo y restauración de AWS Backup |

### 3.2 EC2-Default-SSM-Role

| Atributo | Valor |
|----------|-------|
| **Nombre** | EC2-Default-SSM-Role |
| **Instance Profile** | Sí |
| **Servicio que lo asume** | ec2.amazonaws.com |
| **Políticas AWS Managed** | AmazonSSMManagedInstanceCore, CloudWatchAgentServerPolicy |
| **Políticas Customer Managed** | AWSAccelerator-Default-SSM-S3-Policy |
| **Permission Boundary** | AWSAccelerator-End-User-Policy |
| **Alcance de despliegue** | Todas las cuentas en Root (excepto Management) |
| **Propósito** | Permitir gestión de instancias EC2 vía Systems Manager y CloudWatch |

---

## 4. Políticas IAM Customer Managed

### 4.1 AWSAccelerator-End-User-Policy (Permission Boundary)

Esta política actúa como **Permission Boundary** para limitar los privilegios máximos de los roles creados por usuarios finales.

| Permiso | Tipo | Descripción |
|---------|------|-------------|
| Todos los servicios excepto IAM, Organizations, Account | Allow | Acceso general a servicios AWS |
| IAM Get*/List*, Account GetAccountInformation/List*, Organizations List*/Describe* | Allow | Lectura de información de IAM, cuentas y organización |
| Acciones IAM de gestión de roles (CreateServiceLinkedRole, PassRole, etc.) | Allow | Gestión de roles propios (excluye roles de Control Tower y LZA) |
| Crear roles con Permission Boundary obligatorio | Allow | Solo se pueden crear roles si se adjunta el boundary `AWSAccelerator-End-User-Policy` |
| Gestión de políticas IAM | Allow | Solo para políticas que NO sean del LZA |
| **Cambios de VPC/Networking** | **DENY** | Prohibido crear/modificar VPCs, subnets, route tables, TGW, NAT Gateways, Internet Gateways |
| **Uso de subnets TGW** | **DENY** | Prohibido lanzar instancias en subnets etiquetadas como TGW |

#### Recursos Protegidos (No modificables por usuarios):
- `aws-controltower-*`
- `AWSAccelerator-*`
- `AWSControlTowerExecution`
- `AWSCloudFormationStackSetExecutionRole`
- `cdk-accel-*`

### 4.2 AWSAccelerator-Default-SSM-S3-Policy

| Permiso | Tipo | Recursos |
|---------|------|----------|
| s3:GetObject | Allow | Buckets de SSM, Windows Downloads, Patch Manager por región |

**Propósito:** Permitir a instancias EC2 descargar agentes y parches de SSM desde los buckets oficiales de AWS.

---

## 5. Service Control Policies (SCPs) por OU/Cuenta

| SCP | Aplicada a | Restricciones Principales |
|-----|-----------|--------------------------|
| AWSAccelerator-Core-Guardrails-1 | Infrastructure, Security, Workloads | Protege CloudTrail, Config y recursos LZA |
| AWSAccelerator-Core-Guardrails-2 | Infrastructure, Security, Workloads | Protege GuardDuty, SecurityHub, Macie; bloquea uso de root |
| AWSAccelerator-Security-Guardrails-1 | Audit, LogArchive | Protege recursos de red; exige cifrado en almacenamiento |
| AWSAccelerator-Infrastructure-Guardrails-1 | Network, Perimeter, SharedServices | Protege recursos de red; exige cifrado en almacenamiento |
| AWSAccelerator-Core-Workloads-Guardrails-1 | Workloads/Dev, Workloads/Test, Workloads/Prod | Protege recursos de red; exige cifrado en almacenamiento |
| AWSAccelerator-Core-Sandbox-Guardrails-1 | Workloads/Sandbox | Guardrails específicos para sandbox |
| AWSAccelerator-Suspended-Guardrails | Suspended | Restringe acceso de LZA a recursos |
| AWSAccelerator-Quarantine-New-Object | Cuentas nuevas (automático) | Previene cambios hasta que LZA se ejecute exitosamente |

---

## 6. Resource Control Policies (RCPs)

| RCP | Aplicada a | Descripción |
|-----|-----------|-------------|
| AWSAccelerator-Core-Rcp-Guardrails | Infrastructure, Security, Workloads | Perímetro de datos: permite acceso externo de solo lectura, protege recursos de modificaciones no autorizadas, exige comunicaciones seguras |

---

## 7. Declarative Policies

| Policy | Aplicada a | Descripción |
|--------|-----------|-------------|
| AWSAccelerator-Vpc-Block-Public-Access-Guardrail | Security, Workloads/Dev, Workloads/Test, Workloads/Prod, Network, SharedServices | Bloquea acceso público a VPCs |

---

## 8. Gestión de Identidades

| Componente | Configuración |
|------------|---------------|
| **Identity Center (SSO)** | Habilitado, delegado a cuenta SharedServices |
| **Grupos IAM** | No se definen grupos IAM locales (gestión vía Identity Center) |
| **Usuarios IAM locales** | No se crean usuarios IAM locales (gestión vía Identity Center) |

---

## 9. Matriz Resumen de Privilegios por Tipo de Usuario

| Tipo de Usuario/Rol | Puede crear recursos AWS | Puede modificar red/VPC | Puede modificar IAM | Puede acceder a servicios de seguridad | Puede usar root |
|---------------------|--------------------------|------------------------|--------------------|-----------------------------------------|-----------------|
| End User (con boundary) | ✅ (con restricciones) | ❌ | ⚠️ (solo roles con boundary) | ❌ (lectura solamente) | ❌ |
| EC2 Instance (SSM Role) | ❌ | ❌ | ❌ | ❌ | N/A |
| Backup Role | ❌ (solo backup/restore) | ❌ | ❌ | ❌ | N/A |
| Administrador (Identity Center) | Según permisos SSO asignados | Según permisos SSO asignados | Según permisos SSO asignados | Según permisos SSO asignados | ❌ |

---

## 10. Notas Importantes

1. **No se crean usuarios IAM locales** en las cuentas. El acceso humano se gestiona a través de AWS IAM Identity Center (SSO) delegado a la cuenta SharedServices.
2. **Permission Boundary obligatorio**: Cualquier rol creado por usuarios debe tener adjunto el boundary `AWSAccelerator-End-User-Policy`, lo que garantiza que ningún rol creado por usuarios pueda exceder los privilegios definidos.
3. **Protección de infraestructura de red**: Las SCPs y la End-User-Policy prohíben explícitamente la modificación de recursos de red (VPCs, subnets, route tables, Transit Gateway, etc.).
4. **Protección de roles del sistema**: Los roles de Control Tower, LZA y CDK están protegidos contra modificación por usuarios.
5. **Cifrado obligatorio**: Las SCPs exigen cifrado en servicios de almacenamiento.
6. **Cuarentena automática**: Las cuentas nuevas se colocan en cuarentena hasta que LZA se ejecute exitosamente.

---

*Documento generado a partir de la configuración del Landing Zone Accelerator v1.1.0 - Hub and Spoke*
