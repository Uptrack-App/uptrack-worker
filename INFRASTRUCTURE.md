# Uptrack Worker — Infrastructure

## Cluster Overview

Multi-region check consensus: 3 continents, 4 nodes, pg process groups.

| Node | Role | Location | Tailscale IP | Specs |
|------|------|----------|-------------|-------|
| nbg1 | Main app (primary) | EU / Nuremberg | REMOVED_MAIN_TS_IP_1 | 4 CPU, 8GB |
| nbg2 | Main app (standby) | EU / Nuremberg | REMOVED_MAIN_TS_IP_2 | 4 CPU, 8GB |
| worker1-us-ashburn | Check worker | US / Virginia | 100.69.152.35 | 2 CPU, 2.5GB |
| worker2-india | Check worker | Asia / Hyderabad | 100.96.28.118 | 3 ARM64, 18GB |

## Erlang Distribution

- **Mode**: Long names (`-name`, not `-sname`)
- **Cookie**: `REMOVED_ERLANG_COOKIE`
- **Cluster strategy**: libcluster Epmd (static node list)
- **Transport**: Tailscale mesh (WireGuard encrypted)

### Node Names

```
uptrack@REMOVED_MAIN_TS_IP_1          # nbg1
uptrack@REMOVED_MAIN_TS_IP_2          # nbg2
uptrack_worker@100.69.152.35  # worker1-us-ashburn
uptrack_worker@100.96.28.118  # worker2-india
```

## Worker Nodes

### worker1-us-ashburn (RackNerd)

- **Provider**: RackNerd KVM VPS ($28/yr Black Friday 2025)
- **Public IP**: REMOVED_US_WORKER_IP
- **OS**: NixOS 24.11 (x86_64)
- **Specs**: 2 vCPU, 2.5GB RAM, 43GB disk
- **SSH**: `ssh root@REMOVED_US_WORKER_IP`
- **NerdVM Panel**: https://nerdvm.racknerd.com/ (REMOVED_PROVIDER_ACCOUNT)
- **Renewal**: Nov 2026

### worker2-india (Oracle Cloud)

- **Provider**: Oracle Cloud Free Tier (Always Free A1.Flex)
- **Public IP**: REMOVED_ASIA_WORKER_IP
- **OS**: NixOS 25.05 (aarch64)
- **Specs**: 3 OCPU ARM64, 18GB RAM
- **SSH**: `ssh root@REMOVED_ASIA_WORKER_IP`
- **Region**: Hyderabad (ap-hyderabad-1)

## Deployment

### US Worker (x86_64)

```bash
# 1. Copy source
rsync -avz --exclude '_build' --exclude 'deps' --exclude '.git' \
  ~/repos/uptrack-app/uptrack-worker/ root@REMOVED_US_WORKER_IP:/opt/uptrack-worker/

# 2. Build release on target
ssh root@REMOVED_US_WORKER_IP "cd /opt/uptrack-worker && \
  MIX_ENV=prod mix deps.get --only prod && \
  MIX_ENV=prod mix release"

# 3. Deploy and restart
ssh root@REMOVED_US_WORKER_IP "rm -rf /opt/uptrack-worker-release && \
  cp -r /opt/uptrack-worker/_build/prod/rel/uptrack_worker /opt/uptrack-worker-release && \
  chown -R uptrack-worker:uptrack-worker /opt/uptrack-worker-release && \
  systemctl restart uptrack-worker"

# 4. Verify
ssh root@REMOVED_US_WORKER_IP "journalctl -u uptrack-worker --since '10 sec ago' --no-pager"
```

### India Worker (ARM64)

Same steps, different host:

```bash
# 1. Copy source
rsync -avz --exclude '_build' --exclude 'deps' --exclude '.git' \
  ~/repos/uptrack-app/uptrack-worker/ root@REMOVED_ASIA_WORKER_IP:/opt/uptrack-worker/

# 2. Build release on target (ARM64 — must build on target)
ssh root@REMOVED_ASIA_WORKER_IP "cd /opt/uptrack-worker && \
  MIX_ENV=prod mix deps.get --only prod && \
  MIX_ENV=prod mix release"

# 3. Deploy and restart
ssh root@REMOVED_ASIA_WORKER_IP "rm -rf /opt/uptrack-worker-release && \
  cp -r /opt/uptrack-worker/_build/prod/rel/uptrack_worker /opt/uptrack-worker-release && \
  chown -R uptrack-worker:uptrack-worker /opt/uptrack-worker-release && \
  systemctl restart uptrack-worker"

# 4. Verify
ssh root@REMOVED_ASIA_WORKER_IP "journalctl -u uptrack-worker --since '10 sec ago' --no-pager"
```

## Systemd Service

Both workers run as `uptrack-worker.service` with these env vars:

| Var | US Worker | India Worker |
|-----|-----------|-------------|
| NODE_REGION | us | asia |
| MAIN_NODES | uptrack@REMOVED_MAIN_TS_IP_1,uptrack@REMOVED_MAIN_TS_IP_2 | same |
| RELEASE_COOKIE | REMOVED_ERLANG_COOKIE | same |
| MIX_ENV | prod | prod |

## How Consensus Works

1. Each worker runs MonitorProcess GenServers for all monitors
2. Each process performs HTTP checks independently from its region
3. After each check, result is broadcast via `pg` process group to all nodes
4. Each node computes consensus: majority down = down, otherwise up
5. Only the "home node" (hash-based) fires alerts — prevents duplicates

## Troubleshooting

```bash
# Check cluster connectivity
ssh root@REMOVED_US_WORKER_IP "ping -c 1 REMOVED_MAIN_TS_IP_1"  # US → EU
ssh root@REMOVED_ASIA_WORKER_IP "ping -c 1 REMOVED_MAIN_TS_IP_1"    # India → EU

# Check service logs
ssh root@REMOVED_US_WORKER_IP "journalctl -u uptrack-worker -f"
ssh root@REMOVED_ASIA_WORKER_IP "journalctl -u uptrack-worker -f"

# Connect to running node (IEx remote shell)
ssh root@REMOVED_US_WORKER_IP "/opt/uptrack-worker-release/bin/uptrack_worker remote"

# Check cluster membership from main app
ssh nbg1 "/nix/store/*/bin/uptrack remote"
# then: Node.list()
```

## Known Issues

- India: `nixos-rebuild switch` fails on bootloader — use `nixos-rebuild test -I nixos-config=/etc/nixos/configuration.nix`
- India: `awk: command not found` in stop script (harmless)
- Workers don't write to DB or trigger alerts — only check + broadcast
