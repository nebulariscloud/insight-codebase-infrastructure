# IPAM IP Address Allocation

```mermaid
graph TD
    classDef global fill:#1a1a2e,stroke:#e94560,color:#fff,stroke-width:2px
    classDef regional fill:#16213e,stroke:#0f3460,color:#fff,stroke-width:2px
    classDef pool fill:#264653,stroke:#2a9d8f,color:#fff,stroke-width:1px
    classDef vpc fill:#0f3460,stroke:#53a8b6,color:#fff,stroke-width:1px

    GLOBAL["Global Pool<br/><code>10.0.0.0/8</code><br/><i>16,777,216 IPs</i>"]:::global

    REGIONAL["Regional Pool<br/><code>10.0.0.0/12</code><br/><i>1,048,576 IPs</i>"]:::regional

    GLOBAL --> REGIONAL

    REGIONAL --> INGRESS_P["Ingress Pool<br/><code>10.0.0.0/20</code><br/><i>→ Perimeter</i>"]:::pool
    REGIONAL --> EGRESS_P["Egress Pool<br/><code>10.0.16.0/24</code><br/><i>→ Perimeter</i>"]:::pool
    REGIONAL --> EP_P["Endpoints Pool<br/><code>10.0.20.0/22</code><br/><i>→ Network</i>"]:::pool
    REGIONAL --> SS_P["SharedServices Pool<br/><code>10.0.24.0/21</code><br/><i>→ SharedServices</i>"]:::pool
    REGIONAL --> DEV_P["Dev Workloads Pool<br/><code>10.4.0.0/14</code><br/><i>→ Network</i>"]:::pool
    REGIONAL --> TEST_P["Test Workloads Pool<br/><code>10.8.0.0/14</code><br/><i>→ Network</i>"]:::pool
    REGIONAL --> PROD_P["Prod Workloads Pool<br/><code>10.12.0.0/14</code><br/><i>→ Network</i>"]:::pool

    INGRESS_P --> V_ING["Ingress VPC /20"]:::vpc
    EGRESS_P --> V_EG["Egress VPC /24"]:::vpc
    EP_P --> V_EP["Endpoints VPC /22"]:::vpc
    SS_P --> V_SS["SharedServices VPC /21"]:::vpc
    DEV_P --> V_DEV["Shared Dev VPC /16"]:::vpc
    TEST_P --> V_TEST["Shared Test VPC /16"]:::vpc
    PROD_P --> V_PROD["Shared Prod VPC /16"]:::vpc
```

## Address Space Summary

| Pool | CIDR | Size | VPC | Account |
|------|------|------|-----|---------|
| Ingress | `10.0.0.0/20` | 4,096 IPs | Ingress VPC | Perimeter |
| Egress | `10.0.16.0/24` | 256 IPs | Egress VPC | Perimeter |
| Inspection | `10.0.17.0/24` | 256 IPs | *Not deployed* | — |
| Endpoints | `10.0.20.0/22` | 1,024 IPs | Endpoints VPC | Network |
| SharedServices | `10.0.24.0/21` | 2,048 IPs | SharedServices VPC | SharedServices |
| Dev Workloads | `10.4.0.0/14` | 262,144 IPs | Shared Dev VPC | Network |
| Test Workloads | `10.8.0.0/14` | 262,144 IPs | Shared Test VPC | Network |
| Prod Workloads | `10.12.0.0/14` | 262,144 IPs | Shared Prod VPC | Network |
