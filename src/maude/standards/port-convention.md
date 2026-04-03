---
title: Port Convention Standard
type: standard
version: 1.1.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-03-29
status: MANDATORY
---

# Port Convention Standard

## Purpose

Self-documenting port assignments for all Maude Room MCP servers. CTID = port
eliminates the need for a port allocation registry and makes firewall rules
predictable across sites. Implements Art. II Sec. 3 (sanctioned interfaces) and
Art. III Sec. 3 (traceability — self-documenting port allocation).

## Rules

**CTID = MCP Port.** Every Maude Room daemon MUST listen on a port equal to its Proxmox CTID. This makes the port self-documenting: if you know the CTID, you know the port.

## Site Ranges

Each site occupies a distinct port range derived from the CTID numbering scheme:

| Site | CTID Range | MCP Port Range | Example |
|------|-----------|----------------|---------|
| site-a | 100–199 | 100–199 | grafana (CTID 140) → port 140 |
| site-b | 300–399 | 300–399 | site-b coordinator (CTID 380) → port 380 |
| site-c | 400–499 | 400–499 | Reserved |
| site-d | 500–599 | 500–599 | Reserved |

## Multi-Service Hosts

When a single CTID hosts multiple MCP services (e.g., Maude), the primary service uses the CTID as its port and additional services use sequential offsets:

| CTID | Service | Port | Rule |
|------|---------|------|------|
| 200 | proxmox | 200 | CTID (primary) |
| 200 | unifi | 201 | CTID + 1 |
| 200 | unas | 202 | CTID + 2 |

The ordering MUST be: infrastructure first (proxmox), then network (unifi), then storage (unas).

## Exceptions

| Host | Port | Reason |
|------|------|--------|
| control-plane (900) | 900 | CTID = port (follows convention) |
| gpu-node-1 (standalone) | 9300 | Not a Proxmox LXC — no CTID |
| gpu-node-2 (standalone) | 9301 | Not a Proxmox LXC — no CTID |

## Implementation

The port MUST be set in two places per service:

1. **`/app/{service}/maude.env`** — `MAUDE_PORT={ctid}` (used by systemd ExecStart)
2. **`/app/{service}/config-local.yaml`** — `port: {ctid}` (metadata, used by health loop)

The systemd template `maude@.service` reads `MAUDE_PORT` from the env file and passes it as `--port` to the Python server.

## Examples

**Standard mapping:**
- Grafana site-a (CTID 140) → MCP port 140
- PostgreSQL site-b (CTID 330) → MCP port 330
- DNS site-c (CTID 453) → MCP port 453

**Multi-service host:**
- Coordinator site-a (CTID 200): proxmox=200, unifi=201, unas=202

**Exception (standalone GPU):**
- gpu-node-1 → port 9300 (not a Proxmox LXC, no CTID)

## Enforcement

Enforced by `validate-registry.py` which checks that `mcp_port` matches CTID
in `registry/rooms.yaml` for standard Maude Rooms. Exceptions MUST be
documented in the Exceptions table above.
