# Memory Profile Runbook — 150k-Monitor Bump

Diagnostic procedure to identify the dominant memory consumer at scale,
*before* committing to a Rust migration. The migration argument changes
significantly depending on which of the five hypotheses below is true.

## Hypotheses

| # | Hypothesis | What you'd see | Fix-in-Elixir difficulty | Rust win magnitude |
|---|---|---|---|---|
| (a) | Per-MonitorProcess Gun/Mint conns not shared | High `connection_processes.gun.count` ≈ MonitorProcess count | 1–2 wk (move to Finch with shared pools) | ~3–5× |
| (b) | Finch pool growing unbounded with diverse hosts | High `connection_processes.finch_pool.count` + grows over time | 1 wk (bound `pool_count` and `pool_max_idle_time`) | ~3–5× |
| (c) | Receive-buffer growth on long-lived idle conns | High `memory_categories.binary_mb`, low refc churn | 1 wk (tune `SO_RCVBUF`, shorter idle timeout) | ~2–3× |
| (d) | HTTP/2 frame buffering on multiplexed conns | High `connection_processes.{gun,finch_pool}.per_process_bytes.p99` | medium (cap concurrent streams per conn) | ~2–3× |
| (e) | GenServer state bloat from accumulated check history | High `monitor_processes.per_process_bytes.p99` >> `p50`; spread across many MonitorProcess pids | medium (trim history rings, hibernate idle, off-heap large state) | **~10×** |

If **(e) dominates** → Rust wins ~10× per task, strongest case for migration.
If **(a) or (b) dominates** → Elixir reconfiguration *might* fix it in 1–2 weeks
without migrating. Rust still wins but the urgency drops.
If **both** dominate ~equally → Rust wins ~50×, strongest case for full
migration.

## Procedure

### 1. Snapshot under steady load

```bash
# Connect a remote console to the loaded node (substitute the node name):
iex --remsh uptrack_worker@nbg1

# Or via :erpc from main app console:
iex> :erpc.call(:"uptrack_worker@nbg1", UptrackWorker.MemoryProfile, :snapshot, [])
```

### 2. Stream snapshots over time

```elixir
# Run from the loaded node to capture drift across the bump.
for i <- 1..20 do
  snap = UptrackWorker.MemoryProfile.snapshot()
  File.write!("/tmp/profile-#{i}.txt", inspect(snap, pretty: true, limit: :infinity))
  Process.sleep(60_000)
end
```

### 3. Interpretation cheat sheet

Read the snapshot in this order:

1. **`memory_categories`** — the gross breakdown. If `binary_mb` ≫ `processes_mb`,
   the cost is in refc binaries (hypothesis c). If `processes_mb` dominates,
   the cost is per-process state (hypothesis a/d/e).

2. **`monitor_processes.per_process_bytes`** — `p50` and `p99` close = uniform
   MonitorProcess size (no bloat). `p99` ≫ `p50` = a subset of monitors are
   accumulating state (hypothesis e).

3. **`connection_processes`** — `count` near MonitorProcess count means
   per-monitor conns (hypothesis a). `count` ≫ unique destination hosts
   means pool growth without reuse (hypothesis b).

4. **`top_processes_by_memory`** — concrete offenders. The pid, initial_call,
   and current_function show whether the worst memory hog is a MonitorProcess,
   a connection pool, or something else (a stuck logger? an Oban worker?).

5. **`ets_tables`** — look for unbounded ETS growth (caches, registries).

6. **`ports.by_kind`** — high `"tcp_inet"` count tells you raw socket pressure;
   compare against `monitor_processes.count`.

## MetricsQL queries (VictoriaMetrics)

For historical view of the bump rather than a point-in-time snapshot. Adjust
`{node="..."}` to the loaded probe.

### Total BEAM memory over time (catch the slope of the bump)

```promql
beam_memory_total_bytes{node=~"nbg1|nbg2"}
```

### Per-category breakdown (only useful if you export these — see Notes)

```promql
sum by (category) (beam_memory_bytes{node="nbg1"})
```

### Process count over time

```promql
beam_processes_count{node="nbg1"}
```

### Monitor cadence distribution (to estimate per-second check load)

```promql
count by (interval_seconds) (uptrack_monitor_status)
```

### Unique-host distribution (does conn pooling actually help here?)

If you tag check results with the target host, this answers
"how many monitors hit how many unique hosts":

```promql
count by (host) (uptrack_monitor_status)
```

Then sort the result and bucket — if 80% of monitors hit the top 100 hosts,
pooling is a huge win. If unique hosts ≈ monitor count, pooling gains are
limited.

### Notes on metrics availability

The current worker doesn't appear to export BEAM-level metrics to
VictoriaMetrics (no `prom_ex`/`telemetry_metrics_prometheus` was found in
the worker deps). For historical analysis you have two options:

1. **Add `prom_ex` with the `BeamMetrics` plugin** — one-time setup, ~30 min.
   Then `beam_memory_total_bytes`, `beam_processes_count`, GC, schedulers
   become queryable from VM.
2. **Run the snapshot script on a loop** (procedure step 2 above) and grep
   `total_mb`/`processes_mb` out of the saved files. Cheap, no new deps.

For the diagnostic question we have here (which hypothesis dominates),
option 2 is enough.

## Synthetic-load reproduction

If you can't get a production node to 150k right now, reproduce the bump
synthetically using the existing `UptrackWorker.Tools.bench/1` helper:

```elixir
:erpc.call(:"uptrack_worker@nbg1", UptrackWorker.Tools, :bench, [10_000])
:erpc.call(:"uptrack_worker@nbg1", UptrackWorker.Tools, :bench, [50_000])
:erpc.call(:"uptrack_worker@nbg1", UptrackWorker.Tools, :bench, [150_000])
```

Then snapshot at each level. `bench/1` spawns fake monitors against
`http://127.0.0.1:1` so no real connections form — this isolates the
per-MonitorProcess overhead (hypothesis e) from the connection overhead
(hypotheses a–d). Comparing the synthetic snapshot to a real-load snapshot
of the same monitor count tells you how much of the bump is connections
vs. process state.

## Decision branches once you have data

- **MonitorProcess p99 ≫ p50, refc binary high** → fix history rings + binary
  references; revisit Rust only if fix doesn't move the needle.
- **MonitorProcess uniform, Gun process count ≈ monitor count** → switch HTTP
  client to Finch with shared pools; reassess.
- **Both look fine but `total_mb` still bumps** → likely conn-pool memory at
  the C/NIF layer (`:ssl` session cache). Investigate `:ssl_session_cache`
  table size and `partial_chain` validation overhead.
- **Per-monitor state genuinely irreducible** → that's the Rust case. Take
  numbers to the migration OpenSpec and proceed with Phase 1 spike.
