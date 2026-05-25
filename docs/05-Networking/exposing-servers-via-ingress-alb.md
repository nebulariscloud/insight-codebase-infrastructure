# Exposing Servers to the Internet via the Ingress ALB

## Overview

This document describes how to expose private workload servers to the internet using the centralized ingress Application Load Balancer (ALB) deployed in the Perimeter account. The ALB is the only sanctioned entry point from the public internet into the Landing Zone — direct internet exposure of workload servers is blocked by VPC Block Public Access controls and the security architecture.

## Architecture

```
Internet
   │
   ▼
[Route 53] (optional, custom domain)
   │
   ▼
[Internet Gateway] (Perimeter account, ingress VPC)
   │
   ▼
[Ingress ALB] ── public subnets, ingress-public-a / ingress-public-b
   │   - WAF attached (managed rules + rate limiting)
   │   - HTTP→HTTPS redirect when cert present
   │   - HTTPS termination at the ALB
   ▼
[Transit Gateway] (Network account)
   │   - Static routes between ingress and shared-prod CIDRs
   ▼
[Workload Server] ── shared-prod-app-a / shared-prod-app-b
                     (Production account, RAM-shared subnets)
```

### Key facts

| Item | Value |
|---|---|
| Ingress VPC | `AWSAccelerator-us-east-2-ingress` (Perimeter account) |
| Ingress VPC CIDR | `10.0.0.0/20` |
| Shared-prod VPC CIDR | `10.12.0.0/14` |
| ALB DNS | `ingress-alb-122459471.us-east-2.elb.amazonaws.com` |
| ALB security group | Inbound 80/443 from `0.0.0.0/0` |
| Region | `us-east-2` |

## Generic process: Expose any server through the ALB

Repeat these steps for each new application you want to expose. The ALB and supporting infrastructure already exist — you do not need to re-run the LZA pipeline.

### Step 1 — Launch the server (Production account)

1. EC2 → **Launch instance**
2. Choose your AMI (Linux, Windows, marketplace AMI, etc.)
3. Network settings:
   - VPC: the shared-prod VPC (`AWSAccelerator-us-east-2-shared-prod`)
   - Subnet: `AWSAccelerator-us-east-2-shared-prod-app-a` or `-app-b`
   - Auto-assign public IP: **Disable**
4. Launch
5. Note the instance's **private IP address** and **instance ID**

### Step 2 — Configure the server's security group (Production account)

EC2 → Security Groups → select the SG attached to the instance.

Add an inbound rule:

| Field | Value |
|---|---|
| Type | Custom TCP (or HTTP/HTTPS) |
| Port | The port your app listens on (e.g., 80, 443, 8080) |
| Source | `10.0.0.0/20` (ingress VPC CIDR) |
| Description | `Allow ALB traffic` |

Remove any unnecessary `0.0.0.0/0` inbound rules. The ALB is the only legitimate source of traffic — the server should not accept connections from anywhere else.

### Step 3 — Create a target group (Perimeter account)

EC2 → Target Groups → **Create target group**

| Field | Value |
|---|---|
| Target type | **IP addresses** (cross-account targeting requires IP type) |
| Name | `<app>-tg` (e.g., `myapp-tg`) |
| Protocol | HTTP or HTTPS (match what your server speaks) |
| Port | The server's listening port |
| VPC | The ingress VPC |
| Protocol version | HTTP1 (default) unless your app needs HTTP/2 or gRPC |
| Health check protocol | Same as above |
| Health check path | An endpoint that returns 200 (e.g., `/`, `/health`, `/api/status`) |
| Advanced → Success codes | `200` (add `302`, `401` if your app redirects or requires auth on root) |
| Advanced → Healthy threshold | 3 |
| Advanced → Unhealthy threshold | 3 |
| Advanced → Interval | 30 seconds |

Next → Register targets:

| Field | Value |
|---|---|
| Network | **Other private IP address** |
| IP address | Server's private IP from Step 1 |
| Port | Server's port |
| Availability Zone | **all** (critical for cross-account/cross-VPC routing via TGW) |

Click **Include as pending** → **Create target group**.

### Step 4 — Add a listener rule on the ALB (Perimeter account)

EC2 → Load Balancers → click `ingress-alb` → **Listeners and rules** tab.

Choose a routing strategy:

#### Option A — Path-based routing (one domain, many apps)

Click the HTTP:80 listener → **Manage rules** → **Add rule**.

| Field | Value |
|---|---|
| Name | `<app>-path-rule` |
| Condition | **Path** → `/<app>*` (e.g., `/myapp*`) |
| Priority | Pick an unused number (1-50000) |
| Action | **Forward to target group** → select your TG |

#### Option B — Host header routing (different subdomain per app)

Same flow but condition is **Host header** → `myapp.yourcompany.com`.

This requires DNS pointing the subdomain at the ALB.

#### Option C — Default route (one app per ALB)

Edit the listener's default action → forward to your TG. Use this only if a single app owns the entire ALB.

### Step 5 — Verify

1. EC2 → Target Groups → click your TG → **Targets** tab
2. Wait until target shows **healthy** (typically 30-90 seconds)
3. If unhealthy, check:
   - Server is actually listening on the port (`ss -tlnp | grep <port>`)
   - Security group allows `10.0.0.0/20` on that port
   - Health check path returns the expected HTTP code
   - Application logs for errors
4. Test from your laptop:
   ```bash
   curl -v http://ingress-alb-122459471.us-east-2.elb.amazonaws.com/<your-path>
   ```

### Step 6 — Optional: DNS and HTTPS

#### Custom domain

Route 53 → hosted zone → create record:
- Type: A
- Alias: Yes → Application Load Balancer → us-east-2 → select `ingress-alb`
- Save

#### HTTPS

1. AWS Certificate Manager (Perimeter account, us-east-2) → Request public certificate
2. Add domain name(s) → DNS validation → wait for "Issued"
3. Copy the certificate ARN
4. Edit `thenew-aws-accelerator-config/customizations-config.yaml`:
   ```yaml
   - name: CertificateArn
     value: arn:aws:acm:us-east-2:713939170920:certificate/your-cert-id
   ```
5. Rezip and push to the LZA config bucket → pipeline runs → ALB gains an HTTPS listener and HTTP traffic auto-redirects to HTTPS

## Wazuh-specific deployment

Wazuh's [AMI deployment guide](https://documentation.wazuh.com/current/deployment-options/amazon-machine-images/amazon-machine-images.html) targets a public-IP launch in a default VPC. The behavior is the same in our private-subnet model, with these differences:

| Wazuh default | Our environment |
|---|---|
| Public IP for direct access | No public IP — ALB is the entry point |
| Security group `0.0.0.0/0` on multiple ports | Tightened to `10.0.0.0/20` (ALB-only access) |
| SSH via key pair to public IP | SSM Session Manager or EC2 Instance Connect Endpoint |
| Browser to `https://<public-ip>` | Browser to `http://<alb-dns>` (terminates HTTPS at ALB) or `https://<alb-dns>` once cert is added |

### Wazuh-specific configuration

| Item | Value |
|---|---|
| AMI | Wazuh All-In-One Deployment (AWS Marketplace) |
| Instance type | `c5a.xlarge` (per Wazuh recommendation) |
| Storage | 100 GiB gp3 minimum |
| Subnet | `AWSAccelerator-us-east-2-shared-prod-app-a` (Production account) |
| Public IP | Disabled |
| Wazuh dashboard port | **443 (HTTPS)** |
| Default username | `admin` |
| Default password | The instance ID with first letter capitalized (e.g., `I-07f25f6afe4789342`) |
| First-boot wait | ~5 minutes for password initialization |

### Wazuh target group settings

| Field | Value |
|---|---|
| Target type | IP addresses |
| Protocol / Port | **HTTPS / 443** |
| VPC | Ingress VPC |
| Health check protocol | HTTPS |
| Health check path | `/` |
| Health check matcher | `200,302,401` (Wazuh login flow can return any of these) |

### Wazuh security group lockdown

The Marketplace AMI ships with a security group that opens ports `1514`, `1515`, `1516`, `9200`, `9300-9400`, `55000`, and `443` to `0.0.0.0/0`. After the instance is reachable through the ALB:

1. EC2 → Security Groups → Wazuh SG → Edit inbound rules
2. Replace each `0.0.0.0/0` source with one of:
   - `10.0.0.0/20` for port 443 (ALB only)
   - The CIDR or security group of the agents/managers that legitimately need each port (1514/1515 for agents, 55000 for the API, etc.)
3. Save rules

### Accessing Wazuh

1. Wait ~5 minutes after launch for password initialization
2. Browser: `http://ingress-alb-122459471.us-east-2.elb.amazonaws.com`
3. Accept the certificate warning (Wazuh's internal cert is self-signed; the ALB has no cert yet)
4. Login:
   - Username: `admin`
   - Password: `<InstanceID>` with the first letter capitalized
5. After login, change all default passwords following the [Wazuh password management guide](https://documentation.wazuh.com/current/user-manual/user-administration/password-management.html)

### Connecting to the Wazuh instance shell

Since the instance has no public IP, traditional SSH from the internet does not work. Use one of:

#### Option A — SSM Session Manager (recommended)

1. Attach an IAM instance profile with `AmazonSSMManagedInstanceCore` (LZA provides `EC2-Default-SSM-Role`)
2. Systems Manager → Session Manager → **Start session** → select the instance

#### Option B — EC2 Instance Connect Endpoint

Already deployed in the shared-prod VPC. Run:

```bash
aws ec2-instance-connect ssh --instance-id i-xxxxxxxx --os-user wazuh-user
```

Wazuh AMI restricts SSH to user `wazuh-user`. The endpoint generates a one-time key automatically.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Target health: `Target.Timeout` | Server not listening, or SG blocks ALB | SSM into server, check `ss -tlnp`, verify SG allows `10.0.0.0/20` |
| Target health: `Target.FailedHealthChecks` | Health check path returns wrong code | Adjust path or success codes in target group |
| `502 Bad Gateway` | Target group has no healthy targets | Re-check target health |
| `503 Service Unavailable` | No targets registered, or all unhealthy | Register IP, wait for health check to pass |
| `504 Gateway Timeout` | Server is slow or TGW route missing | Check application performance and TGW route table for `10.12.0.0/14` static route |
| Wazuh login fails immediately after launch | First-boot password init not complete | Wait 5 more minutes |
| Pipeline fails: `S3Bucket: ... does not exist` | Access logs bucket missing | Disable access logs in `customizations-config.yaml` (set bucket to `''`) |

## Related documentation

- [Network configuration overview](../05-Networking/) — TGW topology, route tables
- [Security services setup](../04-Security-Identity-Compliance/) — WAF, GuardDuty, Security Hub
- LZA config files: `thenew-aws-accelerator-config/network-config.yaml`, `customizations-config.yaml`, `custom-stacks/ingress-alb.yaml`
