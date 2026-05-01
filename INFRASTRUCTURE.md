# Uptrack Worker — Infrastructure

> Operator runbook. **Real hostnames, IPs, and provider details live in a private wiki / agenix-encrypted notes** — never in this public document.

## Cluster Overview

Multi-region check consensus across 4 nodes spanning 3 continents, coordinated via Erlang `:pg` process groups over a Tailscale (WireGuard) mesh.

| Node | Role | Region |
|------|------|--------|
| Main app (primary) | Phoenix API + coordinator | EU |
| Main app (standby) | Phoenix API + coordinator | EU |
| Check worker | Probe execution | US |
| Check worker | Probe execution | Asia |

Specs vary per provider; see private operator notes for current sizing.

## Erlang Distribution

- **Mode**: Long names (`-name`, not `-sname`)
- **Cookie**: Set via `RELEASE_COOKIE` env var. Must be a strong random value (32+ chars) shared across all nodes. Never hardcode.
- **Cluster strategy**: libcluster Epmd (static node list resolved at boot)
- **Transport**: Tailscale mesh (WireGuard encrypted)

### Node naming convention

```
uptrack@<host>           # Main app (Phoenix API + coordinator)
uptrack_worker@<host>    # Check worker
```

The `uptrack@` vs `uptrack_worker@` prefix is load-bearing — it drives the `MonitorSupervisor.assigned_to_this_node?/1` partition that excludes worker nodes from app-side monitor ownership.

## Worker provisioning

Workers are deployed on small VPS instances (one per region). Any provider works as long as:

- The host can reach the main app via Tailscale
- NixOS or another supported OS is installed
- The `uptrack-worker` service can run as a non-root user
- Outbound HTTP/HTTPS is unrestricted (workers probe arbitrary targets)

Region assignment via `NODE_REGION` env var (`us`, `asia`, `eu`, ...).

## Deployment

### Build & deploy

```bash
# 1. Copy source to the worker host
rsync -avz --exclude '_build' --exclude 'deps' --exclude '.git' \
  ./uptrack-worker/ "$WORKER_HOST:/opt/uptrack-worker/"

# 2. Build the release on the target (architecture must match)
ssh "$WORKER_HOST" "cd /opt/uptrack-worker && \
  MIX_ENV=prod mix deps.get --only prod && \
  MIX_ENV=prod mix release"

# 3. Stage the release and restart
ssh "$WORKER_HOST" "rm -rf /opt/uptrack-worker-release && \
  cp -r /opt/uptrack-worker/_build/prod/rel/uptrack_worker /opt/uptrack-worker-release && \
  chown -R uptrack-worker:uptrack-worker /opt/uptrack-worker-release && \
  systemctl restart uptrack-worker"

# 4. Verify
ssh "$WORKER_HOST" "journalctl -u uptrack-worker --since '10 sec ago' --no-pager"
```

ARM64 workers must build on the target — cross-compilation is not configured.

## Systemd service env vars

Workers run as `uptrack-worker.service`. Required env:

| Var | Purpose |
|-----|---------|
| `NODE_REGION` | Region tag emitted with each check result (`us`, `asia`, `eu`, ...) |
| `MAIN_NODES` | Comma-separated list of `uptrack@<host>` addresses for libcluster |
| `RELEASE_COOKIE` | Strong random cookie shared across all cluster nodes |
| `MIX_ENV` | Always `prod` in deployed environments |
| `APPSIGNAL_PUSH_API_KEY` | Optional. Enables APM. Leave unset to disable AppSignal |

## How consensus works

1. Each worker runs a `MonitorProcess` GenServer per monitor
2. Each process performs HTTP checks independently from its region
3. After each check, the result is broadcast via the `:monitor_checks` pg process group to all nodes
4. Each app node computes consensus: majority down = down, otherwise up
5. Only the "home node" (deterministic hash of `monitor_id`) fires alerts — prevents duplicate pages

## Troubleshooting

```bash
# Check cluster connectivity
ssh "$WORKER_HOST" "ping -c 1 $MAIN_TAILSCALE_IP"

# Stream service logs
ssh "$WORKER_HOST" "journalctl -u uptrack-worker -f"

# Attach an IEx remote shell to a running release
ssh "$WORKER_HOST" "/opt/uptrack-worker-release/bin/uptrack_worker remote"

# Check cluster membership from the main app
ssh "$MAIN_HOST" "/opt/uptrack-release/bin/uptrack remote"
# then in IEx:
Node.list()
```

## Known operational notes

- Workers don't write to Postgres or trigger alerts — they only run checks and broadcast results
- Some ARM64 hosts have NixOS bootloader quirks; consult provider docs
- The `uptrack-worker` release is intentionally stateless — restart loses no durable data
