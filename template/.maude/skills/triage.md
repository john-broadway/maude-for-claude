---
type: skill
domain: triage
description: Investigate service issues through structured log analysis, dependency checks, and escalation decision trees
version: 1.0
---

# Triage Decision Tree

Investigate service issues through structured log analysis, dependency checks, and escalation decision trees


## Key Principles

- Use read-only diagnostic tools (`service_status`, `service_health`, `service_errors`) before any corrective action — understand the failure before attempting to fix it
- If the problem is an upstream dependency (database, network, external API), do not restart this service — restarts cannot fix upstream issues and may cause crash loops
- Check the most common cause first (service down, then resource exhaustion, then configuration), and expand scope only if the obvious cause is ruled out
- Escalate if root cause is not identified within 3 diagnostic iterations — continued probing without a clear direction wastes time
- Never restart a service as a diagnostic step — restart is treatment, not diagnosis

## Step 1: Classify the Problem
- **Service down** → health check, then restart if appropriate
- **Service degraded** → check logs for root cause
- **Upstream issue** → identify which dependency, do NOT restart
- **Resource exhaustion** → check disk, memory, connections

## Step 2: Act or Escalate
- If you can fix it with your tools → fix it
- If the fix requires human judgment → escalate with context
- If you've already tried once and it didn't work → escalate

## Step 3: Remember
- Store the incident as a memory for future reference
- Update knowledge/memory/incidents.md with the pattern

## Process Flow

1. Identify the symptom from the user's report or monitoring alert
2. Check service health to confirm the issue exists
3. Check logs and errors to narrow the root cause
4. Match symptoms to known issues in the Common Issues table
5. Apply the recommended action or escalate if not listed
