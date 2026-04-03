---
type: skill
domain: remediation
description: Execute corrective actions for common service failures including restarts, config reloads, and dependency resolution
version: 1.0
---

# Remediation Playbook — {{PROJECT}}

Execute corrective actions for common service failures including restarts, config reloads, and dependency resolution


## Key Principles

- Confirm diagnosis before taking corrective action — never restart a service based on a symptom report alone; verify with `service_status` and `service_errors` first
- Prefer least-destructive fix: tune configuration or clear a resource constraint before restarting, and restart before recreating
- Verify fix success with the same tool that found the problem — if `service_health` reported the failure, use `service_health` to confirm recovery
- Log what was done and why for the audit trail — every corrective action must be traceable for post-incident review
- If a dependency is down, do not restart this service — restarting cannot fix upstream issues and may cause crash loops or data loss

## Service Restart
If the health endpoint is unreachable or returns errors:
1. Check service status with the status tool
2. If stopped/failed, restart the service
3. Wait 5 seconds, then verify health endpoint again

## Log Volume
If disk usage is high and logs are the cause:
1. Check disk usage
2. Identify large log files
3. Rotate or truncate if safe

## Connection Issues
If the service can't reach dependencies:
1. Check dependency health (use dependency info from knowledge)
2. If dependency is down, note in summary — this is not fixable locally
3. If local network issue, restart the service to reset connections

## Process Flow

1. Confirm the issue is reproducible and not transient
2. Identify the root cause from logs and health data
3. Apply the fix — follow the specific remediation steps for this issue type
4. Verify the fix resolved the issue (re-check health)
5. Document what happened and what was done in the audit trail
