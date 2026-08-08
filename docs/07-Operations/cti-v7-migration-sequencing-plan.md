# CTI v7 Cluster Migration — Sequencing Plan

This covers the CTI v7 cluster: the CTI v7 telephony server, the WS Aheeva file-loader, the two web-application servers, and the shared MySQL database (`iccmaindb`). It is a separate effort from the Aheeva CTI v8.6 migration.

## 1. Summary

We are moving this five-component cluster out of the legacy AWS account into the new, guardrailed environment. The work is staged by risk rather than done all at once: the low-risk, stateless components move first to prove out the process, and the stateful, client-facing components move last in a single coordinated cutover window with a defined rollback path.

Today the low-risk components are live in the new environment, and the high-risk ones are built and staged — waiting on the telephony vendor's server activation, a scoping decision on one auxiliary database, and a scheduled cutover window.

The principle throughout is to keep the blast radius small at every step and never move a component in a way we can't reverse within the rollback window.

---

## 2. Why we sequence the way we do

Four principles drive the ordering.

**a. Easy and reversible first.** The two web-application servers hold no unique state on disk and are not the system of record for anything. If their migration had failed, we could revert instantly with no data at risk. Moving them first let us validate the entire migration pipeline — image copy, encryption re-keying, network placement, load-balancer fronting — on components where a mistake was cheap.

**b. Stateful and client-facing last.** The database and the file-loader (which ingests client files daily) are where data loss or a missed file would actually hurt. These move in a tightly controlled window, after the machinery is proven, with the source environment kept alive as a rollback target.

**c. Long-lead items start early and run in parallel.** Some steps take days regardless of our effort — database replication needs time to synchronize, and a third-party license reissue is a vendor round-trip. We start those as early as possible so they are not on the critical path during the cutover window.

**d. Security posture improves as part of the move, not after.** The legacy environment carried permissive network exposure (a publicly reachable database, broad inbound rules). The migration is the moment we correct that: the destination database is private, network access is scoped to the application tier, and administrative access moves to controlled paths. We do not reproduce the old exposure and clean it up later — the improved posture is built into the destination from the first apply.

---

## 3. The components and their risk profile

| Component | Role | State on disk | Client-facing | Migration risk |
|---|---|---|---|---|
| Web app server | Internal web application | None meaningful | Behind LB, ~internal | Low |
| Web app (PHP 7.3) | Internal web application | None meaningful | Behind LB, internal | Low |
| `iccmaindb` (RDS MySQL) | System-of-record database | Continuous | No (private) | High |
| WS Aheeva | Daily client file ingest → writes to DB | Mutable (file inbox) | Yes (clients push files) | High |
| CTI v7 | Telephony / call handling | Config | Yes (voice carriers) | High, specialised |

The two low-risk rows form **Wave 1**. The high-risk rows form **Wave 2** (plus CTI v7, which was handled on its own track because of specialised telephony and licensing constraints).

---

## 4. Work completed to date

**Wave 1 — the two web-application servers — is live in the new environment.**
Both were migrated as private instances and validated. They continue to use the legacy database for now (the database cutover is intentionally deferred to Wave 2), which keeps Wave 1 fully independent and reversible. This wave confirmed the end-to-end migration pipeline works.

**CTI v7 (telephony) is migrated and running, pending license activation.**
CTI v7 required an environment exception because it is a real-time voice server: it needs a directly reachable public IP and it authenticates its software license against that IP. We implemented that exception in a narrow, tightly-scoped way (it applies only to this one tagged server; every other workload in the account remains fully private). The server is running in the new environment. It cannot carry live calls until the software vendor reissues its license for the new machine — see dependencies below.

---

## 5. The remaining sequence and the reasoning

The remaining work runs as **three parallel tracks** that converge at a single cutover window. Running them in parallel is deliberate — the two slowest items (database synchronization and the vendor license) have external lead time, so they start immediately rather than waiting their turn.

### Track A — Database (start earliest, runs continuously)

**What:** stand up the destination database from a copy of the source, then keep it continuously synchronized with the live source until cutover.

**Why first and why continuous:** a database cannot be moved instantly without either a long outage (copy everything during the window) or ongoing replication (copy once, then stream changes). We chose replication so the eventual cutover is a matter of minutes, not hours. Replication needs to run for a period to catch up and stay caught up, so it is the earliest thing we start.

**Security note:** the destination database is **private** — unlike the source, which was publicly reachable. Access is restricted to the application tier only, and it is encrypted with a key we control rather than a default managed key. This is a material posture improvement delivered by the migration itself.

**Reversibility:** until the cutover moment, the source database remains the live system of record. Nothing is committed until we deliberately promote the destination.

### Track B — Telephony vendor activation for CTI v7 (external dependency, in progress)

**What:** the telephony software vendor activates the migrated server — whitelisting its new public IP on their side and performing the manufacturer-side configuration checks they require before the server is considered production-ready.

**Where it stands:** we have already verified from our side that the migrated server can reach the vendor's licensing endpoint at the IP they provided. So the network path is confirmed. What remains is on the vendor: (a) whitelisting the server's new public IP so licensing succeeds, and (b) the vendor logging into the server to run their own configuration checks and changes as the software manufacturer. This is hands-on vendor work, not something we can complete for them.

**Why in parallel:** the vendor's activation work is on their schedule, not ours, so it runs alongside everything else. CTI v7 cannot carry live calls until they finish, but nothing else in the migration depends on it — so it does not gate the rest of the cluster.

### Track C — File-loader and its client entry point (the WS Aheeva chain)

**What:** migrate the WS Aheeva file-loader and stand up the internet-facing entry point that clients use to deliver files.

**Why this is a short internal sequence:** these three steps must go in order because each depends on the previous — the server must exist before we can point its network entry point at it. This chain is prepared ahead of the window but only finalized during it, because the file-loader's disk changes continuously as clients deliver files. Capturing it too early would migrate stale data; we capture it at the window after pausing inbound files and letting the queue drain, so nothing in flight is lost.

**Security note:** the file-drop entry point is being rebuilt cleanly with a scoped allow-list of the actual client sources, replacing the legacy broad exposure.

### The convergence — the cutover window

The database (Track A) and the file-loader (Track C) must go live **together**, because the file-loader writes into the database and clients write into the file-loader. Splitting them would either drop client files or break the data path mid-flight. So there is a single, planned maintenance window in which we:

1. Pause client file delivery and let the in-flight queue finish processing.
2. Confirm the destination database is fully caught up, then promote it to be the live system of record.
3. Bring the file-loader live in the new environment, pointed at the new database.
4. Repoint the already-migrated web applications to the new database.
5. Give clients the new file-drop endpoint and confirm an end-to-end test file processes correctly.

**Rollback:** the source database and file-loader are kept alive (read-only / paused) for a defined window after cutover — 7 days by default. If anything is wrong, we revert to the source. Nothing legacy is decommissioned until that window closes cleanly.

### Independent finishing items (no cutover dependency)

- **Web-application public endpoint / TLS.** The web apps are reachable today over the internal path; standing up their dedicated public load balancer and applying a TLS certificate is a finishing step that can happen on its own schedule once naming and certificate provisioning are settled. It carries no cutover risk.
- **CTI v7 activation.** When the vendor license arrives (Track B), CTI v7 is brought fully live and voice traffic is cut over to it. Independent of the database/file-loader window.

---

## 6. Dependencies we are waiting on

Two items gate full completion and sit outside the engineering work itself — one with the telephony vendor, one needing a decision from you:

1. **Telephony vendor server activation** (blocks CTI v7 carrying live calls). The network path to the vendor's licensing endpoint is already verified from our side; what remains is the vendor whitelisting the server's new public IP and performing their manufacturer-side configuration checks on the server directly. This is hands-on vendor work on their schedule.
2. **Scope confirmation on a separate reporting database.** There is a reporting database running on its own server, separate from the main application database (`iccmaindb`), used by roughly a dozen downstream consumers. We would like your confirmation on whether it should be included in this migration — moved now, deferred to a later phase, or left in place. It does not block the main cluster cutover, so there is no time pressure on the cutover itself, but **please let us know when we can confirm this decision** so we can plan for it accordingly. We have flagged it here so it is decided deliberately rather than overlooked.

Surfacing these explicitly is deliberate: the vendor activation is the item most likely to move the timeline, and the reporting-database scope is the one decision we need back from you to consider the cluster fully accounted for.

---

## 7. Risk controls summary

| Risk | Control |
|---|---|
| Data loss on the database move | Continuous replication + promote-at-window; source kept read-only for a 7-day rollback window |
| Lost client files during file-loader move | Pause inbound, drain queue, capture the loader only after it is quiesced |
| Broad blast radius from a bad change | Staged by risk; low-risk components proved the pipeline first |
| Reproducing legacy over-exposure | Destination is private-by-default; scoped allow-lists; customer-managed encryption; the migration improves posture rather than carrying it forward |
| Environment exception for the telephony server | Scoped to a single tagged instance; all other workloads remain fully private; reversible |
| Losing institutional knowledge mid-migration | Every step, decision, and identifier is documented in the migration plan and runbook so the work is not dependent on any one person's memory |

---

## 8. Where we are

The reversible, low-risk half of the cluster is already live in the new environment. The high-risk half is built and staged, waiting on database synchronization to run its course, the telephony vendor's activation, and a scheduled cutover window — all in motion or queued. The cutover is designed as a short, reversible window with the legacy environment retained as a fallback until we have confirmed the new one is healthy.
