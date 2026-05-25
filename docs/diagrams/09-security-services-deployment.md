# Security Services Organization-Wide Deployment

```mermaid
graph TD
    classDef admin fill:#e63946,stroke:#d62828,color:#fff,stroke-width:2px
    classDef service fill:#264653,stroke:#2a9d8f,color:#fff,stroke-width:1px
    classDef member fill:#0f3460,stroke:#53a8b6,color:#fff,stroke-width:1px
    classDef output fill:#6a4c93,stroke:#b5838d,color:#fff,stroke-width:1px
    classDef mgmt fill:#1a1a2e,stroke:#e94560,color:#fff,stroke-width:2px

    subgraph AUDIT["Audit Account (021655151355) — Delegated Admin"]
        direction TB
        GD["GuardDuty\nS3 + EKS Protection\nFindings export to S3 every 6hrs"]:::service
        SH["Security Hub\n3 Standards: FSBP, NIST, CIS v3.0\nCross-region aggregation: all regions"]:::service
        MACIE["Macie\n15-min policy findings\nSensitive data discovery"]:::service
        AA["IAM Access Analyzer\nOrg-level external access analysis"]:::service
        INSP["Inspector\nEC2 + ECR + Lambda scanning\nAuto-enable new accounts"]:::service
        CONFIG["AWS Config\n27+ rules, 2 auto-remediations\nDelivery to central S3"]:::service
    end

    subgraph MEMBERS["Member Accounts (11)"]
        direction LR
        M1["LogArchive\n808431466229"]:::member
        M2["SharedServices\n547368325532"]:::member
        M3["Network\n857876979853"]:::member
        M4["Perimeter\n713939170920"]:::member
        M5["Production\n395516496764"]:::member
        M6["Staging\n870150364800"]:::member
        M7["Development\n070502825675"]:::member
        M8["QA\n806997205179"]:::member
        M9["UAT\n832511099188"]:::member
        M10["Sandbox\n470337543799"]:::member
    end

    subgraph OUTPUTS["Centralized Outputs"]
        direction LR
        SNS["SNS Alerting\nHigh / Medium / Low"]:::output
        S3_LOGS["S3 Central Logs\nLogArchive account"]:::output
        CT_LOGS["CloudTrail Logs\nControl Tower bucket"]:::output
    end

    GD -->|"monitors"| MEMBERS
    SH -->|"evaluates"| MEMBERS
    MACIE -->|"scans S3"| MEMBERS
    AA -->|"analyzes policies"| MEMBERS
    INSP -->|"scans workloads"| MEMBERS
    CONFIG -->|"assesses config"| MEMBERS

    SH -->|"findings"| SNS
    GD -->|"export"| S3_LOGS
    CONFIG -->|"snapshots"| S3_LOGS
    SH -->|"aggregates from"| CT_LOGS
```

## Service Enrollment Summary

| Service | Delegated Admin | Member Accounts | Auto-Enroll New Accounts |
|---|---|---|---|
| GuardDuty | Audit (021655151355) | All 11 | Yes |
| Security Hub | Audit (021655151355) | All 11 | Yes |
| Macie | Audit (021655151355) | All 11 | Yes |
| Inspector | Audit (021655151355) | All 11 | Yes |
| IAM Access Analyzer | Audit (021655151355) | Org-level | Yes |
| AWS Config | Audit (021655151355) | All 11 | Yes |

## Security Hub Standards

| Standard | Scope | Status |
|---|---|---|
| AWS Foundational Security Best Practices v1.0.0 | All accounts (Root OU) | Enabled |
| NIST SP 800-53 Rev 5 | All accounts (Root OU) | Enabled |
| CIS AWS Foundations Benchmark v3.0.0 | All accounts (Root OU) | Enabled |
