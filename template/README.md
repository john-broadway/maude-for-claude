# {{PROJECT_TITLE}} MCP

> **Version:** 0.1.0
> **Created:** {{DATE}}
> **Last Updated:** {{DATE}}
> **Status:** Active

Per-project Maude MCP daemon for {{PROJECT_TITLE}} (CTID {{CTID}}, {{IP}}).

## Quick Start

```bash
pip install -e ".[dev]"
pytest tests/ -v
python -m {{PROJECT}}_mcp.server --stdio  # Local testing
```

## Deployment

```bash
# Deploy maude library
rsync -av --delete --exclude='__pycache__' \
  ~/projects/maude/src/maude/ {{SSH_ALIAS}}:/app/maude/src/maude/

# Deploy project source
rsync -av --delete --exclude='__pycache__' --exclude='.git' \
  ~/projects/{{PROJECT}}/ {{SSH_ALIAS}}:/app/{{PROJECT}}/{{PROJECT}}/

# Deploy knowledge (writable by Room Agent)
rsync -av ~/projects/{{PROJECT}}/.maude/ {{SSH_ALIAS}}:/app/{{PROJECT}}/.maude/

# Deploy config + systemd unit
scp config-local.yaml {{SSH_ALIAS}}:/app/{{PROJECT}}/config-local.yaml
scp deploy/maude@{{PROJECT}}.service {{SSH_ALIAS}}:/etc/systemd/system/maude@{{PROJECT}}.service
ssh {{SSH_ALIAS}} "systemctl daemon-reload && systemctl enable maude@{{PROJECT}} && systemctl start maude@{{PROJECT}}"
```

## Architecture

- **Base:** maude.daemon.register_ops_tools (11 standard tools via composition)
- **Domain:** Custom tools in `src/{{PROJECT}}_mcp/tools/`
- **Transport:** Streamable HTTP on port {{MCP_PORT}}
- **Health Loop:** Background health checks with auto-recovery
- **Room Agent:** LLM-powered autonomous agent for L2 triage
