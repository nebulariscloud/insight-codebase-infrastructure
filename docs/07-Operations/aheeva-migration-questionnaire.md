# Aheeva CTI v8.6 + DB Slave — Pre-Migration Questionnaire

This is the information we need from the Aheeva administrator (and where
flagged, from the Aheeva vendor) before we can lock the cutover date and
finalise the migration design.

**Context for whoever is filling this out:** we are migrating two AWS
EC2 instances out of the source AWS account / region (`254422596287`,
`us-east-1`) into the new AWS environment (`395516496764`, `us-east-2`).
The two instances are:

| Role | Source instance | Source private IP | Source public IP |
|---|---|---|---|
| Aheeva CTI v8.6 (app + MySQL master) | `i-085b1b072af56e661` | `10.0.1.92` | `3.217.85.105` |
| Aheeva DB Slave v86 | `i-05b16ebe4f90c2c03` | `10.0.1.172` | `3.228.31.130` |

**Important: the public IP will change.** AWS does not allow Elastic IP
addresses to move between regions. Every external partner that
currently allowlists `3.217.85.105` (and `3.228.31.130` if used) must
allowlist the new IP we provide before the cutover window. We will
coordinate this with at least 7 days lead time.

The migration plan keeps Aheeva working **the same way it does today**:
private box for the slave, master with a public IP for SIP/RTP, MySQL
replication between them. Only the IP and the AWS account change.

Please answer everything you can. If something needs the Aheeva vendor,
flag it and we'll loop them in. The questions marked **CRITICAL** are
the ones that block us from setting a cutover date.

---

## Section 1 — Aheeva license (CRITICAL)

The license file is the single biggest risk for cutover. If it's keyed
to anything that changes in the migration, we need a new one ready
**before** the maintenance window.

> 1.1. Is the Aheeva v8.6 license keyed to:
>   - [ ] EC2 instance ID
>   - [ ] MAC address of the network interface
>   - [ ] Public IP address
>   - [ ] Private IP address
>   - [ ] Hostname / FQDN
>   - [ ] None of the above (perpetual / unkeyed)
>   - [ ] Don't know — please ask vendor
>
> 1.2. Where on disk is the current license file? Full path.
>
> 1.3. What is the procedure to swap in a new license file? (Stop
> services, copy file, restart? Or live reload?)
>
> 1.4. Aheeva account manager / support contact: name, email, support
> portal URL, ticket SLA.
>
> 1.5. If a new license is needed, how long does Aheeva typically take
> to issue one once we open the request?

---

## Section 2 — SIP traffic shape (CRITICAL)

This determines whether the box can stay simple (private + NLB) or
needs the same direct-EIP topology it has today.

> 2.1. For each SIP carrier / partner / trunk, who initiates the SIP
> session?
>   - [ ] Aheeva sends `REGISTER` outbound to the carrier (we register
>         to them)
>   - [ ] Carrier sends `INVITE` inbound to our public IP (they connect
>         to us)
>   - [ ] Both (please specify which carriers do which in 2.2)
>
> 2.2. List of every SIP/voice partner currently active. For each:
>   - Partner name
>   - Direction (inbound to us / outbound from us / both)
>   - The IP/hostname they reach us on (today this is `3.217.85.105`,
>     but is it different for any partner?)
>   - The IP we reach them on
>   - Whether they currently allowlist `3.217.85.105`
>
> 2.3. Does Aheeva use a SIP proxy / SBC / Kamailio / OpenSIPS /
> FreeSWITCH front-end, or does it talk to carriers directly?
>
> 2.4. In `/etc/asterisk/sip.conf` (or `pjsip.conf`), what is the
> current value of:
>   - `externip` (or `external_media_address`):
>   - `localnet`:
>   - `nat`:
>
> If `externip` is set to the literal IP `3.217.85.105`, we need to
> update it to the new IP during cutover. If it's `auto` or set to a
> hostname, we need to know that too.
>
> 2.5. RTP port range — the security group has UDP 10000-20000 open.
> What is the actual range Aheeva uses?
>   - `rtpstart` =
>   - `rtpend` =
>
> 2.6. Does media (RTP) flow directly between carrier and EC2, or
> through a media gateway / RTPproxy?

---

## Section 3 — MySQL replication (CRITICAL)

> 3.1. The slave (`Aheeva DB Slave v86`, currently `10.0.1.172`):
>   - [ ] Read-only replica only (nothing writes to it)
>   - [ ] Backup target (mysqldump / xtrabackup runs here)
>   - [ ] Failover candidate (intended to be promoted)
>   - [ ] Reporting workload (queries by external tools)
>   - [ ] Other:
>
> 3.2. Replication mode:
>   - [ ] Async
>   - [ ] Semi-sync
>   - [ ] Don't know
>
> 3.3. GTID enabled? Run on the master:
> ```
> mysql -e "SHOW VARIABLES LIKE 'gtid_mode'; SHOW VARIABLES LIKE 'enforce_gtid_consistency';"
> ```
>
> 3.4. MySQL version on both boxes:
> ```
> mysql -V
> ```
>
> 3.5. On the master, current binlog position (we'll capture this again
> at cutover, but want to confirm the format now):
> ```
> mysql -e "SHOW MASTER STATUS\G"
> ```
>
> 3.6. On the slave, current replication state:
> ```
> mysql -e "SHOW SLAVE STATUS\G" | grep -E '^(Master_Host|Master_Port|Master_Log_File|Read_Master_Log_Pos|Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master|Auto_Position)'
> ```
>
> 3.7. Does the slave's `master.info` reference the master by IP or by
> hostname? If by IP, we'll need to repoint it during cutover with
> `CHANGE MASTER TO MASTER_HOST=...`.

---

## Section 4 — Internal MySQL clients (CRITICAL)

The current security group allows MySQL `3306/tcp` from these sources:

| Source | Description in current SG |
|---|---|
| `34.230.213.145` | Scriptcase |
| `3.87.101.184` | Webserver-Reportes-Amz |
| `3.84.227.17` | Webserver-Reportes-Amz |
| `172.30.2.118` | webserver php 7.3 |

> 4.1. For each of the four sources above:
>   - Is it still in active use?
>   - Where does it run today (old AWS tenant / on-prem / new AWS
>     tenant / decommissioned)?
>   - If it's been migrated, what's the new private IP in the new
>     tenant?
>   - Does it connect to the public IP `3.217.85.105`, or to the
>     private IP `10.0.1.92`?
>
> 4.2. Are there any **other** systems that connect to MySQL on this
> box that aren't in the allowlist today (maybe via an IPSec tunnel,
> VPN, or VPC peer)?
>
> 4.3. After cutover, every MySQL client needs to point at the new
> master's private IP. We'll provide that during cutover. Confirm who
> on the client team can update those connection strings during the
> window.

---

## Section 5 — External partner allowlists (CRITICAL for scheduling)

The current security group has these external sources allowlisted on
various ports. We need to know which are still in use, so we can give
each one the new IP in advance and confirm they've allowlisted it
before cutover.

| Today's source IP | Description in source SG | Still active? | New IP allowlist confirmed? |
|---|---|---|---|
| `139.71.144.9/32` | AmEx HQ (port 9443) | | |
| `190.60.92.152/29` | ganadero IFX (ICMP) | | |
| `181.204.67.42/32` | ganadero Tigo (all-traffic via SG self) | | |
| `142.112.46.61/32` | Personal Aheeva HQ | | |
| `154.64.223.34/32` | FiberX Kennedy | | |
| `199.116.62.102/32` | FiberX datacenter | | |
| `23.249.138.106/32` | WNet datacenter | | |
| `64.89.2.105/32` | (no description) | | |
| `23.20.175.146/32` | WebService-AWS | | |
| `172.30.2.200/32` | aws-webservice (old tenant) | | |
| `52.200.31.137/32` | n8n (port 22) | | |
| `181.207.82.178/32` | zima (port 22) | | |
| `24.139.143.242/32` | Liberty Insight (default SG) | | |
| `104.136.10.198/32` | Gonzalo (default SG) | | |
| `24.48.215.31/32` | Alex (default SG) | | |
| `24.37.251.218/32` | Aheeva HQ (default SG) | | |
| `72.50.7.251/32`, `72.50.4.220/32`, `72.50.4.69/32`, `72.50.5.124/32` | Alex (multiple) | | |
| `152.203.83.94/32` | Julian | | |

> 5.1. For each row above, please mark:
>   - **Active** — still connecting today, needs new-IP coordination
>   - **Stale** — drop, no allowlist update needed
>   - **Unknown** — we'll treat as stale unless you say otherwise
>
> 5.2. Are there partners NOT in the table above that connect to
> Aheeva today? (Anything via VPN, IPSec, or that uses the public IP
> but isn't in the SG because it goes through SIP/RTP rather than
> SG-controlled ports.)
>
> 5.3. For each "Active" row in 5.1, who is the technical contact
> (email or ticket portal) we'd give the new IP to in advance?

---

## Section 6 — Port usage (NICE TO HAVE)

The current SG opens these ports `0.0.0.0/0`. We default to
**dropping** anything not explicitly confirmed as in use. If a port is
flagged as in use we'll keep it open under the new architecture.

| Port | Protocol | Description in source SG | In use today? | If yes, used by whom? |
|---|---|---|---|---|
| 22 | TCP | n8n + zima `/32`s | | (Replaced by EICE) |
| 443 | TCP | (no description) | | |
| 4000-5000 | TCP | (no description) | | |
| 4232 | TCP | (no description) | | |
| 4331 | TCP | (no description) | | |
| 4343 | TCP | (no description) | | |
| 5002-5004 | TCP | "balanceo de carga de servidores" | | |
| 5060 | TCP | (no description, SIP) | | |
| 5060 | UDP | (no description, SIP) | | |
| 5500 | TCP | "ScreenCapture" | | |
| 5901 | TCP | (no description, looks like VNC) | | |
| 6080 | TCP | (no description) | | |
| 8443 | TCP | (no description) | | |
| 8484 | TCP | (no description) | | |
| 9443 | TCP | "vicc8" + AmEx HQ | | |
| 10000-20000 | UDP | (no description, RTP) | | |
| ICMP | All | "ganadero IFX" `190.60.92.152/29` | | |

> 6.1. Mark each port as Active / Stale / Unknown.

---

## Section 7 — Architecture preference (decision)

We have two viable architectures. They differ in where the public IP
sits and what changes in the AWS environment. The **public IP changes
in both cases** — that's a function of AWS, not our choice.

### Option A — Direct EIP on the CTI EC2 (same shape as today)

- Master EC2 in a public subnet, new Elastic IP.
- Slave EC2 in private subnet (today's slave EIP `3.228.31.130` is dropped — confirm in 5.1 nobody depends on it).
- Aheeva config unchanged except `externip` updated to the new IP.
- **One-time platform change** in the new AWS environment: add an
  Internet Gateway to the workload VPC, add a public subnet, add a VPC
  Block Public Access exclusion, add an SCP exception scoped to a
  resource tag for this server only.
- These platform changes are permanent but narrow — the SCP exception
  only applies to resources tagged `Migrated == AheevaCTI-V86`. No
  other workload in the account is affected.
- Cutover risk: low. Aheeva sees the same network shape it does today.

### Option B — Private EC2 fronted by NLB (cloud-native)

- Master + slave both private.
- Internet-facing NLB in the perimeter account exposes SIP/RTP.
- Aheeva needs `externip` set to the NLB's public IP, plus careful
  configuration so SDP advertises a routable address. Risk of one-way
  audio if codec/NAT settings aren't right on day one.
- **No platform change** in the new AWS environment.
- Cutover risk: medium. Real chance we spend a day or two tuning SIP
  NAT traversal post-cutover.

> 7.1. Preference:
>   - [ ] Option A — direct EIP on EC2 (recommended for simplicity, requires platform change)
>   - [ ] Option B — private + NLB (recommended for cloud-native posture, more cutover risk)
>   - [ ] Defer to us — pick whichever has lower risk
>
> 7.2. Any compliance / security constraints that would block Option A?
> (E.g., a requirement that no workload account directly attaches an
> IGW.)

---

## Section 8 — Cutover window (CRITICAL for scheduling)

> 8.1. Confirmed maintenance window length: ~2 hours of full Aheeva
> outage (no calls answered, agents logged out, MySQL writes blocked,
> recordings paused). Acceptable?
>   - [ ] Yes
>   - [ ] No, max we can absorb is: ___ minutes
>   - [ ] Yes, but we'd like to extend to: ___ for safety buffer
>
> 8.2. Preferred day of week and time of day for cutover.
>
> 8.3. Blackout periods to avoid in the next 30 days (settlement runs,
> end-of-month, partner SLAs, holiday traffic peaks):
>
> 8.4. Who from the client team will be on the bridge during cutover?
> Names, roles, contact methods.
>
> 8.5. Is the Aheeva vendor available on standby? If yes, what's the
> escalation path if Aheeva doesn't come up clean?

---

## Section 9 — Pre-cutover access

We'll need to do some validation work before cutover. Confirm we can:

> 9.1. SSH into both source instances during the prep window (T-7 days
> to T-1 day) to:
>   - Capture the exact MySQL replication state (binlog file/position
>     or GTID set)
>   - Verify Aheeva's `sip.conf` / `pjsip.conf` matches what's been
>     filled in above
>   - Take application-consistent snapshots (`STOP SLAVE` + `FLUSH
>     TABLES WITH READ LOCK` on master, snapshot, unlock) — total ~5
>     minutes of write-blocking on the master
>
> 9.2. Trigger a fresh AMI snapshot of both instances at the time we
> need it (the AMIs in the source today are dated 2022 and 2023 — we
> need fresh ones).
>
> 9.3. SSH access method during prep: existing key-based SSH, AWS
> Systems Manager Session Manager, or something else?

---

## Section 10 — Post-cutover sign-off

> 10.1. What does "migration successful" look like to the client?
> Specific tests to run before we close the maintenance window:
>   - [ ] Inbound test call from each carrier
>   - [ ] Outbound test call to each carrier
>   - [ ] Agent login from one of each agent UI port (8443/9443/etc.)
>   - [ ] MySQL replication shows `Seconds_Behind_Master = 0`
>   - [ ] Recordings get written to the recording bucket / volume
>   - [ ] Other:
>
> 10.2. How long do we keep the source environment alive as a
> rollback target? Default is 7 days post-cutover.
>
> 10.3. After the rollback window, who does the source decommission
> (you or us)?

---

## Returning this

Send completed answers to: [your team email / ticket].

If anything is unclear or you'd like a working session to fill it out
together, message [your team contact].
