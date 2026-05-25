# Matriz de Privilegios - AWS IAM Identity Center

## 1. Información General

| Parámetro | Valor |
|-----------|-------|
| **Servicio** | AWS IAM Identity Center (SSO) |
| **Cuenta Delegada** | SharedServices |
| **Fuente de Identidad** | Identity Center Directory |
| **Región** | us-east-2 |

---

## 2. Modelo de Acceso

El acceso a las cuentas AWS de la organización se gestiona exclusivamente a través de AWS IAM Identity Center. **No se crean usuarios IAM locales en las cuentas.** Los usuarios se asignan a grupos según su rol y responsabilidades, y cada grupo otorga permisos específicos a las cuentas correspondientes mediante Permission Sets.

---

## 3. Grupos de Identity Center

Se han configurado 8 grupos que cubren los diferentes niveles de acceso requeridos:

| # | Grupo | Descripción | Nivel de Acceso |
|---|-------|-------------|-----------------|
| 1 | AWSControlTowerAdmins | Derechos de administrador a cuentas core y provisionadas de AWS Control Tower | Administrador |
| 2 | AWSAuditAccountAdmins | Derechos de administrador a la cuenta de auditoría (cross-account) | Administrador |
| 3 | AWSLogArchiveAdmins | Derechos de administrador a la cuenta de Log Archive | Administrador |
| 4 | AWSServiceCatalogAdmins | Derechos de administrador a Account Factory en AWS Service Catalog | Administrador |
| 5 | AWSSecurityAuditPowerUsers | Acceso de Power User a todas las cuentas para auditorías de seguridad | Power User |
| 6 | AWSSecurityAuditors | Acceso de solo lectura a todas las cuentas para auditorías de seguridad | Solo Lectura |
| 7 | AWSLogArchiveViewers | Acceso de solo lectura a la cuenta de Log Archive | Solo Lectura |
| 8 | AWSAccountFactory | Acceso de solo lectura a Account Factory en AWS Service Catalog para usuarios finales | Solo Lectura |

---

## 4. Detalle de Privilegios por Grupo

### 4.1 AWSControlTowerAdmins

| Atributo | Valor |
|----------|-------|
| **Propósito** | Administración completa de la Landing Zone y Control Tower |
| **Permission Set** | AWSAdministratorAccess |
| **Política Base** | AdministratorAccess (AWS Managed) |
| **Cuentas con Acceso** | Management, Audit, LogArchive, SharedServices, Network, Perimeter y todas las cuentas de Workloads |
| **Acciones Permitidas** | Acceso completo a todos los servicios AWS (sujeto a SCPs) |

**Caso de uso:** Equipo de plataforma/infraestructura responsable de la gestión y operación de la Landing Zone.

---

### 4.2 AWSAuditAccountAdmins

| Atributo | Valor |
|----------|-------|
| **Propósito** | Administración de la cuenta de auditoría de seguridad |
| **Permission Set** | AWSAdministratorAccess |
| **Política Base** | AdministratorAccess (AWS Managed) |
| **Cuentas con Acceso** | Audit |
| **Acciones Permitidas** | Acceso completo a la cuenta Audit (sujeto a SCPs) |

**Caso de uso:** Equipo de seguridad que gestiona las herramientas de auditoría (SecurityHub, GuardDuty, Config aggregator).

---

### 4.3 AWSLogArchiveAdmins

| Atributo | Valor |
|----------|-------|
| **Propósito** | Administración de la cuenta de archivo de logs |
| **Permission Set** | AWSAdministratorAccess |
| **Política Base** | AdministratorAccess (AWS Managed) |
| **Cuentas con Acceso** | LogArchive |
| **Acciones Permitidas** | Acceso completo a la cuenta LogArchive (sujeto a SCPs) |

**Caso de uso:** Equipo responsable de la gestión y retención de logs centralizados (CloudTrail, Config, VPC Flow Logs).

---

### 4.4 AWSServiceCatalogAdmins

| Atributo | Valor |
|----------|-------|
| **Propósito** | Administración de Account Factory para provisionar nuevas cuentas |
| **Permission Set** | AWSServiceCatalogAdminFullAccess |
| **Política Base** | AWSServiceCatalogAdminFullAccess (AWS Managed) |
| **Cuentas con Acceso** | Management |
| **Acciones Permitidas** | Crear, modificar y eliminar productos en Service Catalog; provisionar nuevas cuentas AWS |

**Caso de uso:** Equipo de plataforma que necesita crear nuevas cuentas AWS a través de Account Factory.

---

### 4.5 AWSSecurityAuditPowerUsers

| Atributo | Valor |
|----------|-------|
| **Propósito** | Acceso amplio para investigación y respuesta a incidentes de seguridad |
| **Permission Set** | AWSPowerUserAccess |
| **Política Base** | PowerUserAccess (AWS Managed) |
| **Cuentas con Acceso** | Todas las cuentas de la organización |
| **Acciones Permitidas** | Acceso completo a todos los servicios excepto IAM y Organizations |

**Caso de uso:** Equipo de seguridad que necesita investigar incidentes, ejecutar remediaciones y acceder a recursos en cualquier cuenta.

---

### 4.6 AWSSecurityAuditors

| Atributo | Valor |
|----------|-------|
| **Propósito** | Auditoría de seguridad con acceso de solo lectura |
| **Permission Set** | AWSReadOnlyAccess |
| **Política Base** | ReadOnlyAccess (AWS Managed) |
| **Cuentas con Acceso** | Todas las cuentas de la organización |
| **Acciones Permitidas** | Lectura de configuraciones, recursos y logs en todas las cuentas; sin capacidad de modificar recursos |

**Caso de uso:** Auditores internos o externos que necesitan revisar configuraciones y cumplimiento sin modificar nada.

---

### 4.7 AWSLogArchiveViewers

| Atributo | Valor |
|----------|-------|
| **Propósito** | Consulta de logs centralizados |
| **Permission Set** | AWSReadOnlyAccess |
| **Política Base** | ReadOnlyAccess (AWS Managed) |
| **Cuentas con Acceso** | LogArchive |
| **Acciones Permitidas** | Lectura de logs en S3, CloudWatch Logs y demás servicios de la cuenta LogArchive |

**Caso de uso:** Personal que necesita consultar logs para troubleshooting o auditoría sin acceso administrativo.

---

### 4.8 AWSAccountFactory

| Atributo | Valor |
|----------|-------|
| **Propósito** | Acceso de usuario final a Account Factory |
| **Permission Set** | AWSServiceCatalogEndUserAccess |
| **Política Base** | AWSServiceCatalogEndUserReadOnlyAccess (AWS Managed) |
| **Cuentas con Acceso** | Management |
| **Acciones Permitidas** | Visualizar productos disponibles en Service Catalog; solicitar provisión de cuentas |

**Caso de uso:** Usuarios que necesitan solicitar nuevas cuentas AWS a través del catálogo de servicios.

---

## 5. Matriz Resumen: Grupos × Cuentas

| Grupo | Management | Audit | LogArchive | SharedServices | Network | Perimeter | Workloads |
|-------|:----------:|:-----:|:----------:|:--------------:|:-------:|:---------:|:---------:|
| AWSControlTowerAdmins | ✅ Admin | ✅ Admin | ✅ Admin | ✅ Admin | ✅ Admin | ✅ Admin | ✅ Admin |
| AWSAuditAccountAdmins | — | ✅ Admin | — | — | — | — | — |
| AWSLogArchiveAdmins | — | — | ✅ Admin | — | — | — | — |
| AWSServiceCatalogAdmins | ✅ SC Admin | — | — | — | — | — | — |
| AWSSecurityAuditPowerUsers | ✅ Power | ✅ Power | ✅ Power | ✅ Power | ✅ Power | ✅ Power | ✅ Power |
| AWSSecurityAuditors | ✅ Read | ✅ Read | ✅ Read | ✅ Read | ✅ Read | ✅ Read | ✅ Read |
| AWSLogArchiveViewers | — | — | ✅ Read | — | — | — | — |
| AWSAccountFactory | ✅ SC Read | — | — | — | — | — | — |

**Leyenda:**
- ✅ Admin = AdministratorAccess
- ✅ Power = PowerUserAccess (todo excepto IAM/Organizations)
- ✅ Read = ReadOnlyAccess
- ✅ SC Admin = ServiceCatalog Admin
- ✅ SC Read = ServiceCatalog EndUser (solo lectura)
- — = Sin acceso

---

## 6. Controles de Seguridad Adicionales (Capas de Restricción)

Aunque un Permission Set otorgue permisos amplios, las siguientes capas limitan las acciones efectivas:

| Capa de Control | Efecto | Aplica a |
|-----------------|--------|----------|
| **Service Control Policies (SCPs)** | Limitan acciones máximas por cuenta/OU incluso con permisos de Admin | Todas las cuentas excepto Management |
| **Resource Control Policies (RCPs)** | Perímetro de datos que protege recursos | Infrastructure, Security, Workloads |
| **Permission Boundary** | Limita roles creados por usuarios: prohíbe cambios de red | Roles creados en cuentas de workloads |
| **Declarative Policies** | Bloqueo de acceso público a VPCs | Security, Workloads, Network, SharedServices |

### Restricciones aplicadas por SCPs (aplican incluso a administradores):
- ❌ No se puede desactivar CloudTrail ni AWS Config
- ❌ No se puede modificar GuardDuty, SecurityHub ni Macie
- ❌ No se puede usar la cuenta root
- ❌ No se pueden modificar roles de Control Tower ni del LZA
- ❌ No se pueden modificar recursos de red en cuentas de Workloads (VPCs, subnets, route tables)
- ❌ No se puede desactivar el cifrado en servicios de almacenamiento

---

## 7. Proceso de Asignación de Acceso a Usuarios

```
┌─────────────────────────────────────────────────────────┐
│  1. Identificar rol/responsabilidad del usuario         │
│                         ↓                               │
│  2. Seleccionar grupo apropiado de Identity Center      │
│                         ↓                               │
│  3. Agregar usuario al grupo en IAM Identity Center     │
│                         ↓                               │
│  4. Usuario recibe acceso automático a las cuentas      │
│     asignadas al grupo con los permisos del             │
│     Permission Set correspondiente                      │
│                         ↓                               │
│  5. SCPs y controles adicionales limitan acciones       │
│     efectivas según la cuenta destino                   │
└─────────────────────────────────────────────────────────┘
```

---

## 8. Evidencia de Configuración

### 8.1 Grupos en IAM Identity Center
> *Adjuntar screenshot de: IAM Identity Center → Groups*

### 8.2 Permission Sets
> *Adjuntar screenshot de: IAM Identity Center → Permission sets*

### 8.3 Asignaciones por Cuenta
> *Adjuntar screenshot de: IAM Identity Center → AWS accounts → [cuenta] → Assignments*

---

*Documento preparado para: InsightGroup*  
*Fecha: Mayo 2025*  
*Landing Zone Accelerator v1.1.0 - Hub and Spoke*
