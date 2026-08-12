# WS Aheeva migration — phased plan

Ordered plan for moving WS Aheeva (the FTPS file-loader) from the source tenant into
the new LZA tenant. Written to be walked through on a call: each phase says who does
what, what is needed from whom, and whether the live service is affected.

Companion docs: `cti-v7-wave2-runbook.md` (the actual commands),
`cti-v7-open-items.md` (everything deferred), `cti-v7-migration-sequencing-plan.md`
(why the overall order is what it is).

## The box in one paragraph

WS Aheeva is the server clients drop daily files onto over FTPS. It processes them and
writes the results into the `iccmaindb` database. It is **Windows** (the only Windows
box in this migration), `t3a.medium`, one 80 GiB disk, and it is the disk-mutable,
client-facing member of the cluster — which is why it goes last and why its cutover is
tied to the database.

| | Source | Destination |
|---|---|---|
| Where | source tenant, us-east-1, `172.30.2.200` | `shared-prod`, us-east-2, `10.12.1.66` (confirmed free) |
| Reached by clients | public IP directly | NLB in the Perimeter account |
| Admin access | RDP from 5 allowlisted IPs | SSM port forwarding, no open RDP |
| FTPS passive range | 40000-40500 (501 ports) | 40000-40019 (20 ports) |
| Disk encryption | `aws/ebs` (AWS-managed) | LZA EBS key |

## The one decision that shapes everything: how the final data move happens

The obvious plan is "take a fresh image at cutover so no file is missed." It works, but
it is the slow option, because the cross-account and cross-region image copies are
**full copies, not incremental**. Re-running the whole chain during the cutover window
means roughly one to two hours with FTPS down.

**Recommended instead:** build the destination box once from a rehearsal image, get it
fully configured and tested days ahead, and at cutover move only the **delta** — the
files that arrived since the image was taken. That turns the outage from hours into
minutes, and it means the box going live has been sitting there working, rather than
being freshly created under time pressure.

Trade-off to accept: if anyone changes configuration on the source box between the
rehearsal image and cutover, that change does not come across. Freeze changes on the
source once the image is taken, or note them and reapply by hand.

Delta transfer options, in order of preference — needs a decision before Phase 4:

1. **Via S3.** Source box uploads the spool folder to a bucket, destination pulls it.
   Both boxes already have outbound internet, so no inbound port is opened anywhere.
   Cleanest and auditable.
2. **Destination pulls over the source's own FTPS**, using an admin account. No new
   infrastructure, but does mean an FTPS client on the Windows box.
3. Re-take the full image after all. Only if the delta turns out to be enormous.

Worth measuring first: how big the spool actually is. If files are processed and
archived daily, the delta is small and this is trivial.

---

## Phase 1 — Build the image · no client involvement · zero impact

Nothing here touches the live service. The source box keeps running throughout.

1. Create an image of the source instance (`--no-reboot`, so no interruption).
2. Re-encrypt it onto the transfer key so it can cross accounts, since the source disk
   uses an AWS-managed key that cannot be shared. The key from the osTicket migration
   is reused.
3. Share the image, its snapshot, and the key to the destination account.
4. Copy it into us-east-2, re-encrypting onto the LZA key.

**Needed from the client:** nothing.
**Time:** mostly waiting on copies. Start it and walk away.
**Risk:** none to the live service.

## Phase 2 — Stand the box up · no client involvement · zero impact

5. Deploy the instance leaf. The box comes up private at `10.12.1.66`, reachable only
   from inside, with a security group that allows FTPS from the load balancer and port
   `8081` from CTI v7.
6. Confirm it registers with Session Manager. Windows keeps the SSM agent through this
   kind of move more reliably than Linux does, so this should just work — but three
   Linux boxes in this migration arrived without it, so it gets checked rather than
   assumed.
7. Deploy the FTPS load balancer leaf. This produces the **public IPs the clients will
   need**, which is why it happens before anyone is asked to change anything.

**Needed from the client:** nothing.
**Risk:** none. Two systems now exist in parallel; the old one is still serving.

## Phase 2a — ⚠️ INSERTED 2026-08-12: install the SSM agent on the SOURCE box

**This was not in the original plan and is now the gating step.** It needs the client,
but it is a much smaller ask than the Administrator password.

### What happened

The instance came up healthy and never registered with Systems Manager. Everything that
could explain it away was eliminated:

| Check | Result |
|---|---|
| Instance state / status checks | `running`, `ok` / `ok` |
| Instance profile | `EC2-Default-SSM-Role`, correctly attached |
| Console screenshot | Clean Windows lock screen — no `chkdsk`, no recovery |
| Network path | Proven — `ddhelper` is SSM-managed in the same subnet |
| IMDSv2 too new for an old agent? | **Tested and ruled out.** Replaced the instance with `http_tokens = optional`; still did not register. |
| `user_data` installing the agent | Did not execute — expected on a never-Sysprepped image, where EC2Launch treats user data as already consumed |

Conclusion: **the SSM agent is not present in the image**, and there is no way to put it
there from outside, because there is no way in. On Windows there is no SSH fallback, and
Session Manager was the one path that did not need the Administrator password.

### The ask — small, safe, and not the password

Have the client's admin install the current SSM Agent **on the source box**, over their
existing RDP access:

```
https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/windows_amd64/AmazonSSMAgentSetup.exe
```

Quiet install, no reboot, no interruption to FTPS:

```powershell
Start-Process -FilePath .\AmazonSSMAgentSetup.exe -ArgumentList '/quiet','/norestart' -Wait
Get-Service AmazonSSMAgent | Select-Object Name, Status, StartType
```

Nothing needs configuring — no role, no registration, no account details. The agent only
has to *exist* in the image; it picks up its identity from the instance profile in our
account when it boots there.

### Why the source and not the destination

- **It avoids needing the Administrator password at all for this step.** They run one
  installer; no credential changes hands. A far easier conversation.
- **It fixes the cutover image too.** The image taken at cutover comes from this same
  source box. Fix it there and every future image is manageable; fix it only in the
  destination and the work has to be redone at cutover.
- **A current agent supports IMDSv2**, so the security posture comes back instead of
  living with a workaround.

Then: re-take the AMI (Part 2 of the runbook), update `ami_id`, redeploy. The instance is
replaced, which needs an `ALLOW-DESTROY:` line in the PR description.

### Fallback if they cannot or will not

`AWSSupport-ResetAccess` to regenerate the Administrator password — possible now only
because the `ws-aheeva-admin` key pair is attached, since that automation encrypts the
new password to the instance's key pair. Then RDP without exposing anything publicly, by
port-forwarding through `ddhelper`:

```bash
aws ssm start-session --region us-east-2 --target i-0a1b064b3ad88f87d \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["10.12.1.66"],"portNumber":["3389"],"localPortNumber":["13389"]}'
```

Needs a Terraform change first to allow 3389 from `10.12.1.16/32`, added as a dedicated
rule rather than via `extra_app_ports` — that variable is a cartesian product with
`extra_app_cidrs`, so it would also wrongly open 8081 to `ddhelper` and 3389 to CTI v7.

Two caveats: pass an existing `SubnetId` in us-east-2a so the automation does not try to
build a temporary VPC and internet gateway that the LZA guardrails would deny, and note
it also creates `AWSSupport-EC2Rescue-*` IAM roles and Lambda functions, which LZA may
refuse in Production.

## Phase 3 — Configure inside the box · ⚠️ needs the Administrator password

**This is where the password is needed.** Everything above runs without it — including,
now, Phase 2a.

8. Log in over SSM port forwarding (no RDP exposed to the internet).
9. Narrow the FTPS passive range from 501 ports to 20, and set the server to advertise
   the load balancer's public IP in its passive replies. Without the second part, the
   server tells clients to connect to its own private address and every transfer fails.
10. Fix Windows Firewall. It is a second firewall that AWS security groups say nothing
    about, and because the load balancer rewrites the source address, **any existing
    rule that allowlists client IPs will stop matching.** Same applies to the FTPS
    server's own IP restrictions if it uses them.
11. Update anything inside the box still referencing the old address `172.30.2.200`.
12. Test a real transfer end to end: connect, list a directory, upload a file. A
    directory listing that hangs after a *successful* login is the classic symptom of a
    passive-range or advertised-address mismatch.

**Needed from the client:**
- **The local Administrator password.** See the fallback below if it cannot be produced.
- **Whether the box is domain-joined.** If it is, we need a local admin account that
  works, because the new location may have no path to a domain controller.

**Risk:** still none to the live service — this is all on the new box.

### If the password genuinely cannot be produced

There is a fallback: AWS has a documented automation
(`AWSSupport-ResetAccess`) that resets the local Administrator password on a Windows
instance. It stops the instance, does its work through a helper, and hands back a
password retrievable with a key pair.

It is a real option, not a hack, but it is not free: more moving parts, requires
stopping the box, and it does **not** help if the application runs under a domain
service account whose password we also do not have. Treat it as the safety net, not the
plan.

## Phase 4 — Cutover · ⚠️ needs client coordination · this is the outage

Tied to the database cutover, because WS Aheeva writes to `iccmaindb`. One window, both
moves.

13. Clients pause sends. Drain whatever is still queued on the source and confirm it
    processed.
14. Move the delta files (the decision from the top of this document).
15. Confirm the database replica has caught up, stop replication, and **flip the
    database out of read-only** — until that happens the loader physically cannot write.
16. Point WS Aheeva's database connection at the new endpoint.
17. Clients switch to the new endpoint and resume. Verify a real file lands and lands
    in the database.

**Needed from the client, with lead time — not on the day:**
- The eight FTPS clients need the new endpoint, and they must allow **both** load
  balancer public IPs outbound. Both, not one: the load balancer spans two zones and
  has two addresses, while the FTPS server can only advertise one of them. A client that
  allows only the address it dials will see failures that look random and get blamed on
  everything else first.
- The four clients that are Insight's own sites (three Kennedy, one Liberty) already
  have VPN tunnels into the new environment and could eventually send files privately
  instead of over the internet. **Deliberately not part of this cutover** — it would
  mean changing their address and their routing in the same window as everything else.
  Good follow-up once the public path is proven.

**Downtime:** minutes, if the delta approach is used. Hours, if the image is re-taken.

## Phase 5 — After · no rush

18. Watch it for a few days. The old box stays intact and stoppable, so rollback is
    "point the clients back."
19. Retire the source box only once everyone is happy.
20. Remove the old allowlist entries that were only there for the source.

---

## What to say on the call, in one minute

The migration itself is not blocked and does not need anything from the client to
start. We can build the new server, stand it up, and put the load balancer in front of
it without touching the live system at all — the old box keeps serving the whole time.

Two things are needed, at different moments:

**Before we can finish configuring it:** the Windows Administrator password for the
server, and confirmation of whether it is joined to a domain. Without those we can
build the box but not complete it.

**Before the switchover, with lead time:** the eight companies that send files need the
new address, and they need to allow two IP addresses on their side. That is the piece
with a lead time attached, so the earlier it starts the better.

The switchover itself happens together with the database move, in one window, and should
be a matter of minutes rather than hours.

### The one new ask, as of 2026-08-12

Before the password conversation, there is now a smaller and more urgent request: **install
the SSM Agent on the current WS Aheeva server.** It is a silent install, needs no reboot,
and does not interrupt the file service. Their admin already has RDP access, so nobody has
to share a password to do it.

Why it matters: without that agent we have no administrative access to the migrated server
at all — Windows offers no alternative route — and installing it on the current server also
means the final image taken at switchover is correct, so the work is not repeated.

### Para la llamada (client-facing)

Podemos empezar la migración de inmediato y sin ningún impacto: levantamos el servidor
nuevo, lo dejamos privado y le ponemos el load balancer delante, mientras el servidor
actual sigue funcionando normalmente. No hace falta nada de su parte para esta etapa.

Necesitamos dos cosas, en momentos distintos:

1. **Para terminar la configuración:** el password del **Administrator** de Windows del
   servidor, y confirmar si el servidor está unido a un **dominio**. Sin eso podemos
   construirlo pero no dejarlo operativo. (Si el password no aparece, existe una
   alternativa vía automatización de AWS, pero implica reiniciar el servidor y es
   preferible evitarla.)
2. **Antes del switchover, con tiempo de anticipación:** los **ocho clientes** que
   envían archivos por FTPS necesitan la nueva dirección, y deben permitir **las dos IPs
   públicas** del load balancer en su salida. Dos, no una — este es el detalle que más
   se olvida y provoca fallos intermitentes difíciles de diagnosticar.

El switchover se hace junto con el de la base de datos, en una sola ventana, y debería
tomar **minutos**, no horas. El servidor actual queda intacto por si hay que revertir.

**Pedido adicional (2026-08-12), y es el más urgente:** necesitamos que su administrador
instale el **SSM Agent** en el servidor WS Aheeva **actual**. Es una instalación
silenciosa, **no requiere reboot** y **no interrumpe** el servicio de archivos:

```
https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/windows_amd64/AmazonSSMAgentSetup.exe
```
```powershell
Start-Process -FilePath .\AmazonSSMAgentSetup.exe -ArgumentList '/quiet','/norestart' -Wait
Get-Service AmazonSSMAgent | Select-Object Name, Status, StartType
```

No hay que configurar nada — ni rol, ni registro, ni credenciales nuestras. El agente solo
tiene que **estar instalado** en el servidor.

Por qué importa: sin ese agente **no tenemos ningún acceso administrativo** al servidor
migrado. En Windows no existe una vía alterna (no hay SSH), así que el servidor arranca
correctamente pero queda inaccesible. Además, instalarlo en el servidor **actual** hace que
la imagen final del switchover ya venga correcta, evitando repetir el trabajo.

Ventaja para ustedes: **este paso no requiere compartir el password de Administrator.** Su
administrador lo ejecuta con el acceso RDP que ya tiene.
