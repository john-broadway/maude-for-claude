# Report Formatting Standard

> **Version:** 1.0
> **Created:** 2026-01-20
> **Last Updated:** 2026-02-06 12:11 MST
> **Status:** MANDATORY

Standards for formatting analysis reports, summaries, and documentation.

## Executive Summary Pattern

All reports should lead with an "At a Glance" callout box for key metrics:

```markdown
> **At a Glance**
> - **Total Files:** 363,109
> - **Total Size:** 1.2 TB
> - **Compliance Issues:** 47 (12 ITAR, 35 PII)
> - **Action Items:** 156
```

**Rules for "At a Glance":**
- Maximum 5 metrics
- Most important metric first
- Use bold for labels
- Include units (files, GB, etc.)
- Round large numbers appropriately (363K vs 363,109 for casual reference)

## Table vs Prose Decision

### Use Tables When:
- Comparing 3+ items across multiple attributes
- Displaying structured data (file lists, metrics)
- Showing relationships between categories
- Data will be scanned, not read linearly

### Use Prose When:
- Explaining reasoning or methodology
- Describing a process or workflow
- Providing context for a decision
- Narrative flow matters more than data lookup

### Hybrid Pattern

For complex information, combine both:

```markdown
## Folder Structure Analysis

The site-b location has **2,847 folders** across 12 levels of nesting (violates 6-level max).

| Depth | Folders | % of Total | Status |
|-------|---------|------------|--------|
| 1-3   | 234     | 8%         | Compliant |
| 4-6   | 1,892   | 66%        | Compliant |
| 7-12  | 721     | 25%        | Needs flattening |

The deepest paths are in `Engineering/Projects/` where legacy project structures
were migrated without restructuring.
```

## Phase Separation

For multi-phase reports, use double horizontal rules to separate phases:

```markdown
## Phase 1: Discovery

[Discovery content...]

---
---

## Phase 2: Analysis

[Analysis content...]

---
---

## Phase 3: Recommendations

[Recommendations content...]
```

Single rules (`---`) separate sections within a phase.
Double rules (`---\n---`) separate major phases.

## Metrics Formatting

### Numbers
| Range | Format | Example |
|-------|--------|---------|
| < 1,000 | Exact | 847 files |
| 1,000 - 999,999 | Comma-separated | 12,847 files |
| 1M+ | Abbreviated | 1.2M files |

### Sizes
| Range | Format | Example |
|-------|--------|---------|
| < 1 KB | Bytes | 847 bytes |
| 1 KB - 999 KB | KB | 234 KB |
| 1 MB - 999 MB | MB | 47.3 MB |
| 1 GB+ | GB/TB | 1.2 TB |

### Percentages
- Use whole numbers when possible: 47%
- One decimal for precision: 47.3%
- Always include % symbol

## Status Indicators

Use consistent emoji for status:

| Status | Indicator | Usage |
|--------|-----------|-------|
| Complete/Pass | green check | Verified, compliant, done |
| In Progress | hourglass | Working, pending |
| Warning | warning sign | Needs attention, review |
| Blocked/Fail | red X | Failed, non-compliant |
| Planned | calendar | Scheduled, future |
| Not Applicable | dash | N/A, not relevant |

## PDF Export Requirements

Reports intended for PDF export should:

1. **Avoid wide tables** - Max 5 columns, or split into multiple tables
2. **Use explicit page breaks** - `\newpage` or `---` before major sections
3. **Include TOC placeholder** - `[TOC]` at document start
4. **Test rendering** - Verify tables don't wrap awkwardly

## Cross-Reference Pattern

When referencing other documents or rules:

```markdown
See [Folder Structure Rules](folder-structure.md) for depth limits.
Related agent: `compliance-chief`
```

## Report Header Template

```markdown
# [Report Title]

> **Generated:** 2024-01-20
> **Scope:** [What was analyzed]
> **Agent:** [Agent that generated this]

> **At a Glance**
> - **Key Metric 1:** Value
> - **Key Metric 2:** Value

## Executive Summary

[2-3 paragraph summary...]

## Detailed Findings

[Body of report...]

## Recommendations

[Action items...]

## Appendix

[Supporting data...]
```
