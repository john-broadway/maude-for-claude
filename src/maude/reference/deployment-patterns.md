# Multi-Site Deployment Patterns

Extracted from completed plans (2026-02-20 sweep). Referenced from MEMORY.md.

## SSCNN Numbering Standard

`SS × 100 + C × 10 + NN` where:
- **SS** = Site code (1=site-a, 3=site-b, 4=site-c, 5=site-d)
- **C** = Category (0=infra, 1=data, 2=observability, 3=apps, 4=OT, 5=security, 6=network, 9=maude)
- **NN** = Instance (01-99)

Example: site-b PostgreSQL = 310, site-b Redis = 311, site-b Grafana = 320, site-b lab-service = 340.

## Full Site Package (Minimum per Location)

9 core LXCs: PostgreSQL, Redis, Grafana, Prometheus, Loki, Uptime Kuma, Gitea, Maude, Authentik
3 OT LXCs: Collector (data collection), Panel (HMI), Lab-service (lab MES)
= 12 minimum. Additional: InfluxDB, Qdrant, Workbench (as needed).

## Secondary-Site-First Deployment Strategy

1. Secondary site (site-b) goes live FIRST as safety net
2. Site-b runs independently (WAN-down = ops continue)
3. Only THEN apply site-a Maude rename
4. Validates multi-site code before touching production site-a

## Deploy-Fleet Multi-Site

- `deploy-fleet.sh --site site-b` for per-site deploys
- `dependencies.yaml` has `site:` field per room
- `DependencyGraph.site_rooms()` + `DependencyGraph.sites()` methods in maude

## WAN-Down Degradation

| Service | Behavior When WAN Down |
|---------|----------------------|
| PLC/SCADA | Unaffected (local) |
| HMI | Unaffected (local) |
| Lab-service | Unaffected (local) |
| Room Agents | Health-loop-only (no LLM) |
| Gitea | Read from local push mirror |
| DNS | Local Technitium serves cached |
| Monitoring | Local Prometheus/Grafana |
| Cross-site queries | Unavailable |

## Remote Site Deployment Lessons

**VPN connection throttling:** SSH from the control plane to remote LXCs over a site-to-site VPN gets throttled after 4-5 parallel connections. TCP state exhaustion at the tunnel level. Fix: use ONE remote LXC as a jump host (mux connection), stage artifacts there, distribute via local site network.

**Jump host pattern:** `ssh -o ControlMaster=yes -o ControlPath=/tmp/ssh-mux/host -o ControlPersist=600 -fN target` → single TCP tunnel, unlimited multiplexed commands. Then `scp -o ControlPath=...` for file transfer. Stage JW key temporarily for local distribution, clean up after.

**Pre-start checklist (MANDATORY before `systemctl start maude@*`):**
1. ReadWritePaths dirs exist: `/app/{project}/.maude`, `/app/{project}/knowledge`, `/var/lib/maude-agents/{project}` — status 226/NAMESPACE if missing
2. `maude.env` has correct `MAUDE_MODULE` — check `src/{module}/server.py` path, NOT project name
3. `config-local.yaml` exists at `/app/{project}/config-local.yaml` with correct site IPs
4. `pyproject.toml` + `README.md` at `/app/maude/` — pip install fails without README.md (hatchling)
5. Subprojects (collector, panel, workbench) may have `mcp/` subdirectories with `src/{module}/` layout — need separate pip install

**MAUDE_MODULE naming:** Almost always `{project}_mcp.server`. Exceptions:
- `uptimekuma_mcp.server` (no underscore between uptime/kuma)
- `maude.coordinator.mcp` (Maude)
- Subprojects: `collector_mcp.server`, `hmi_mcp.server`, `workbench_mcp.server` (in `mcp/` subdir)

**Config-local.yaml site overrides:** CTID (3xx), IP (198.51.100.x), events.db_host (site-b PostgreSQL), heartbeat_url (site-b Uptime Kuma). Room agents disabled initially, enable after validation.

## Gitea One-Way Model

Site-a is source of truth. Other sites have read-only push mirrors for emergency manual deploys. No bidirectional sync.

## DNS-Network Coupling (Critical Blocker)

Primary site re-addressing touches 200-300 code refs across 50 files (secrets.yaml, sites.py, Grafana datasources, Gitea remotes, DNS records). CANNOT proceed without DNS fully operational. Dependency chain:
1. DNS site-a disk cleanup + drift fix
2. DNS site-b deployment
3. Site-b network standardization
4. Site-a re-addressing

## VLAN Elimination Pattern

When removing a VLAN from a site:
1. GET full `port_overrides` array from switch
2. Replace only the target port entry (preserve all others)
3. PUT back complete array
4. If device has static IP (not DHCP), it goes offline — revert immediately, flag for on-site
5. Verify connectivity after each device move
