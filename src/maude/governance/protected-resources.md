---
title: "Protected Resources Registry"
type: governance
version: 2.0.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-04-01
---

# Protected Resources Registry

Per Article VII Sec. 4: "Certain systems operate under external
authority. Maude observes and protects them but does not
modify them."

This registry is maintained by Management. Each entry documents
what is protected, who has authority, and what Maude may
do (observe/backup) versus what it may not (configure/modify).

---

## Example: Site-A (192.0.2.0/24)

| Resource | Authority | May Observe | May NOT Modify |
|----------|-----------|-------------|----------------|
| Industrial PLCs | Process Engineering | Tag values, faults, controller status | Ladder logic, configuration, firmware |
| Network gateway | Network Infrastructure | Device status, clients, events | Firewall rules, VLAN config, firmware |
| Managed switches | Network Infrastructure | Port status, PoE, traffic | Port config, VLAN assignment |
| Wireless APs | Network Infrastructure | Client count, channel, signal | WiFi config, RF settings |
| NVR / Cameras | Physical Security | Camera status, NVR health | Recording config, camera settings |
| NAS storage | IT Operations | Share status, disk health | Share config, permissions |

## Example: Site-B (198.51.100.0/24)

| Resource | Authority | May Observe | May NOT Modify |
|----------|-----------|-------------|----------------|
| Industrial PLCs | Process Engineering | Tag values, faults | Ladder logic, configuration |
| Network gateway | Network Infrastructure | Device status, clients | Firewall rules, VLAN config |
| Temperature controllers | Process Engineering | Temperature, setpoints | PID tuning, configuration |

## Example: Site-C (203.0.113.0/24)

| Resource | Authority | May Observe | May NOT Modify |
|----------|-----------|-------------|----------------|
| Network gateway | Network Infrastructure | Device status | Network configuration |
| CNC controllers | Machine Operators | Machine data, DNC status | G-code, machine parameters |

---

## External Services (all sites)

| Resource | Authority | May Observe | May NOT Modify |
|----------|-----------|-------------|----------------|
| Cloud identity provider | IT Operations | User/group sync status | Identity config (admin portal only) |
| Cloud office suite | IT Operations | API reads | Tenant config (admin portal only) |
| PLC programming software | Process Engineering | License status | Activation, configuration |

---

## Rules of Engagement

1. **Observe freely** — monitoring, metrics collection, health
   checks, and backup of protected resources is authorized.
2. **Never modify** — configuration changes, firmware updates,
   software installations, and direct writes are forbidden.
3. **Escalate, don't act** — if a protected resource is
   malfunctioning, report to the listed authority. Do not attempt
   remediation.
4. **Backup is observation** — taking backups of protected resource
   configurations is permitted and encouraged.
5. **MCP tools respect boundaries** — all industrial controller
   tools are read-only by design. No tool exists that can modify
   industrial controllers.
