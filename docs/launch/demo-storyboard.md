# Demo storyboard — `/maude:found` catches a rename orphan

> Recording target: 60–90 seconds. Asciinema or screen recording. The arc should land on a single concrete moment: she sees something `ls` couldn't.

## Setup before recording

Stand up a tiny dev stack pointed at a workspace path, then rename the source directory. Docker still holds the old path open via the running container; on restart it auto-creates an empty bind-source root-owned. That's the failure shape `/maude:found` should now classify as `[GHOST]`.

```bash
# Pick a sandbox dir. Replace with whatever you want.
DEMO=/tmp/maude-demo
rm -rf "$DEMO" && mkdir -p "$DEMO/recipe/data/postgres" && cd "$DEMO"

# Tiny compose file binding to ./recipe/data/postgres
cat > recipe/docker-compose.yml <<'YAML'
services:
  postgres:
    image: postgres:16-alpine
    container_name: maude-demo-postgres
    environment:
      POSTGRES_PASSWORD: demo
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
YAML

# Bring it up so docker bakes ./recipe/data/postgres → host path
( cd recipe && sudo docker compose up -d )

# Wait until healthy
sleep 6

# Rename the recipe directory to simulate the failure mode:
# Container's bind path is now baked at OLD location.
sudo mv recipe staged-recipe

# Restart the container — daemon will recreate the (now missing) bind
# source as root-owned empty dir at the OLD path.
sudo docker restart maude-demo-postgres
sleep 3
```

At this point: the container is running on a fresh empty postgres init at the old path; the original 6-second-old data is at `staged-recipe/data/postgres/`; the workspace has a root-owned ghost-shaped directory at the old path. Exactly the failure mode the running-services walk was built for.

## Recording

Open Claude Code in `/tmp/maude-demo`. Then:

```
/maude:found --refresh
```

What the audience should see scroll past:
- "RUNNING CONTAINERS:" — `maude-demo-postgres`
- "BIND MOUNTS touching this workspace:"
  - `[GHOST]   maude-demo-postgres  /tmp/maude-demo/recipe/data/postgres → /var/lib/postgresql/data  (root-owned + empty — likely auto-created bind stub)`
- A house-map written to `.maude/plugin/house-map.md`
- Maude's "I noticed" line proposing the safe sequence (stop → remove container → rm path)

Then for the punch:

```
ls recipe/
```

`No such file or directory` — the path that docker is bound to doesn't exist on this filesystem in the way docker thinks it does. The user couldn't have spotted this from `ls` alone. Maude did.

## Voiceover beats (if narrating)

1. *"This is the failure mode where a directory rename leaves a running stack pointed at a path that no longer exists."*
2. *"Plain `ls` shows you a tree; it doesn't tell you that a process is bind-mounted to an old version of it."*
3. *"Maude's arrival walk does. She lists running containers, reconciles their bind mounts against the filesystem, and tells you which are intact, which are orphaned, and which are empty stubs the daemon auto-created."*
4. *"That's the running-services awareness in the arrival walk."*

## Cleanup after recording

```bash
cd /tmp
sudo docker rm -f maude-demo-postgres 2>/dev/null
sudo rm -rf /tmp/maude-demo
```

## Notes for the editor

- Best clip is the `[GHOST]` line scrolling past — that's the moment.
- The `ls recipe/` reveal is the proof-of-blindspot — keep it tight.
- Don't speed up the walk's output; let it scroll at native speed. Reading her output IS the demo.
- Subtitle worth showing: `maude — the running-services walk`
