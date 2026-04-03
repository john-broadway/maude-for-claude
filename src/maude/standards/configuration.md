---
title: Configuration Standard
type: standard
version: 1.1.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-02-14
status: MANDATORY
---

# Configuration Standard

## Purpose

Standardized layered configuration for all Maude projects. Every service runs with
safe defaults that ship with the code, while production values remain under local
control and are never overwritten by deployment.

## Rules

1. **Three configuration tiers.** Every service MUST use exactly three tiers,
   loaded in this order (last wins):

   | Tier | Source | Checked In | Deployed | Purpose |
   |------|--------|-----------|----------|---------|
   | 1 | Default config file | YES | YES | Safe defaults and schema reference |
   | 2 | Local override file | NO (.gitignore'd) | NO (never overwritten) | Per-instance production overrides |
   | 3 | Environment variables | NO | Via systemd or process manager | Secrets and bootstrap values |

2. **Tier 1 — Defaults.** MUST contain every config key the project uses, set to
   safe development values. This file is the schema reference — a new contributor
   reading it SHOULD understand every knob available.

3. **Tier 2 — Local overrides.** MUST be listed in `.gitignore`. MUST NOT be
   deployed automatically. Contains production-tuned intervals, model selections,
   site-specific thresholds. This file is owned by the operator.

4. **Tier 3 — Environment variables.** MUST be used for secrets (database URLs,
   API keys, tokens) and bootstrap values (module name, port). Secrets MUST NOT
   appear in any config file checked into source control.

5. **Key naming.** All config keys MUST use `snake_case`. Boolean values MUST be
   `true`/`false` (not `yes`/`no`, `on`/`off`, or `1`/`0`).

6. **Deploys never overwrite local tuning.** Deployment scripts MUST sync only
   default config and code. Production instances have locally tuned values that
   MUST survive deploys.

7. **Credential storage.** Secrets that cannot be environment variables MUST live
   in a dedicated credentials file on the target host. This file MUST NOT be
   committed or deployed — it is provisioned once during setup.

## Examples

### Tier 1 — Default config (checked in, safe defaults)

```yaml
# Safe development defaults — deployment ships this file
service:
  name: collector
  port: 8100

schedule:
  health_check_interval: 300    # 5 min — conservative default
  data_collection_interval: 60

thresholds:
  disk_warning_pct: 80
  disk_critical_pct: 95
```

### Tier 2 — Local overrides (NOT checked in, production values)

```yaml
# Production tuning — NOT deployed, locally managed
schedule:
  health_check_interval: 120    # Tighter in production
  data_collection_interval: 30
```

### Tier 3 — Environment variables (secrets and bootstrap)

```bash
# Loaded by systemd EnvironmentFile= or process manager
SERVICE_MODULE=collector
SERVICE_PORT=8100
DATABASE_URL=postgresql://user:password@db.example.com:5432/mydb
REDIS_URL=redis://cache.example.com:6379/0
```

### How the layers compose

Given the above files, the runtime config resolves to:

```
service.name              = "collector"         # Tier 1 (no override)
schedule.health_check     = 120                 # Tier 2 overrides Tier 1's 300
DATABASE_URL              = "postgresql://..."   # Tier 3 (env var, not in config)
```

### What NOT to do

```yaml
# BAD: secrets in a checked-in config file
database:
  password: "hunter2"

# BAD: yes/no instead of true/false
features:
  enable_caching: yes
```

## Enforcement

- **Deployment scripts:** MUST validate that default config exists and local
  overrides are never in the deploy payload.
- **.gitignore audit:** Local override files MUST appear in every project's
  `.gitignore`. CI SHOULD check for this.
- **Code review:** Reviewers MUST reject secrets in config files and verify that
  new config keys have defaults in Tier 1.
- **Constitutional basis:** The Constitution establishes credential governance
  and data sovereignty; this standard implements them for service configuration.
