# Network Architecture — Shared VPC Model (No Inspection)

## High-Level Traffic Flow

```mermaid
graph TD
    classDef internet fill:#e63946,stroke:#d62828,color:#fff,stroke-width:2px
    classDef tgw fill:#f77f00,stroke:#e36414,color:#fff,stroke-width:2px
    classDef perim fill:#264653,stroke:#2a9d8f,color:#fff,stroke-width:1px
    classDef core fill:#6a4c93,stroke:#8ac926,color:#fff,stroke-width:1px
    classDef shared fill:#3a0ca3,stroke:#7209b7,color:#fff,stroke-width:1px

    INET["Internet"]:::internet

    INGRESS["Ingress VPC\n10.0.0.0/20\nPerimeter Account"]:::perim
    EGRESS["Egress VPC\n10.0.16.0/24\nPerimeter Account"]:::perim

    TGW["Transit Gateway\nASN 64512\nNetwork Account"]:::tgw

    ENDPOINTS["Endpoints VPC\n10.0.20.0/22\nNetwork Account"]:::core
    SHAREDSVCS["SharedServices VPC\n10.0.24.0/21\nSharedServices Account"]:::core

    SHAREDDEV["Shared Dev VPC\n10.4.0.0/16\nNetwork Account"]:::shared
    SHAREDTEST["Shared Test VPC\n10.8.0.0/16\nNetwork Account"]:::shared
    SHAREDPROD["Shared Prod VPC\n10.12.0.0/16\nNetwork Account"]:::shared

    INET <-->|"IGW + Public Subnets"| INGRESS
    INET <-->|"IGW + NAT Gateways"| EGRESS

    INGRESS <-->|"TGW Attach"| TGW
    EGRESS <-->|"TGW Attach"| TGW

    TGW <-->|"TGW Attach"| ENDPOINTS
    TGW <-->|"TGW Attach"| SHAREDSVCS
    TGW <-->|"TGW Attach"| SHAREDDEV
    TGW <-->|"TGW Attach"| SHAREDTEST
    TGW <-->|"TGW Attach"| SHAREDPROD
```

## TGW Route Tables

```mermaid
graph LR
    classDef tgw fill:#f77f00,stroke:#e36414,color:#fff,stroke-width:2px
    classDef rt fill:#264653,stroke:#2a9d8f,color:#fff,stroke-width:1px
    classDef vpc fill:#1d3557,stroke:#457b9d,color:#fff,stroke-width:1px

    RT_FW["Firewall Route Table"]:::rt
    RT_SPOKE["Spoke Route Table"]:::rt

    EGRESS_VPC["Egress VPC"]:::vpc

    RT_FW -->|"0.0.0.0/0"| EGRESS_VPC
    RT_SPOKE -->|"0.0.0.0/0"| EGRESS_VPC

    A_EG["Egress VPC"]:::tgw -->|"associated"| RT_FW
    A_ING["Ingress VPC"]:::tgw -->|"associated"| RT_SPOKE
    A_EP["Endpoints VPC"]:::tgw -->|"associated"| RT_SPOKE
    A_SS["SharedServices VPC"]:::tgw -->|"associated"| RT_SPOKE
    A_DEV["Shared Dev VPC"]:::tgw -->|"associated"| RT_SPOKE
    A_TEST["Shared Test VPC"]:::tgw -->|"associated"| RT_SPOKE
    A_PROD["Shared Prod VPC"]:::tgw -->|"associated"| RT_SPOKE
```

## VPC Detail — Subnet Layout

| VPC | Account | CIDR | Subnets per AZ | Key Features |
|-----|---------|------|----------------|--------------|
| Ingress | Perimeter | 10.0.0.0/20 | FW, Public, TGW | Internet Gateway, inbound traffic |
| Egress | Perimeter | 10.0.16.0/24 | FW, Public, TGW | Internet Gateway, 2x NAT Gateways |
| Endpoints | Network | 10.0.20.0/22 | Endpoint, TGW | Central interface endpoints: ec2, ecr, kms, logs, ssm, monitoring |
| SharedServices | SharedServices | 10.0.24.0/21 | Web, App, Data, TGW | Org-wide shared services |
| Shared Dev | Network | 10.4.0.0/16 | TGW + custom | Subnets shared via RAM to Dev accounts |
| Shared Test | Network | 10.8.0.0/16 | TGW + custom | Subnets shared via RAM to Test accounts |
| Shared Prod | Network | 10.12.0.0/16 | TGW + custom | Subnets shared via RAM to Prod accounts |
