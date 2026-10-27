# Keeping dependencies free of known CVEs

Same three steps as the truckex repo:

| Step | What | Where |
|---|---|---|
| **Detect** | Every lockfile is checked against the OSV advisory database | `scripts/security-audit.sh`, run by `.github/workflows/audit.yml` |
| **Block** | With `AUDIT_ENFORCE=true` a finding fails the run | repo variable `AUDIT_ENFORCE` |
| **Fix** | Renovate opens the bump PRs | `renovate.json` |

Checked here: `mix.lock`.

The audit runs on every push to `main`, every pull request, every **Monday
06:00 UTC** and by hand (Actions > "Security audit" > Run workflow). The weekly
run matters: new CVEs are published against code that did not change. GitHub
emails only the person who last changed the `cron:` line, so also look at the
Actions tab on Mondays.

Run it locally (it downloads a pinned osv-scanner and checks its SHA-256):

```bash
scripts/security-audit.sh
```

## Turning enforcement on

A repo with an open backlog starts in warn-only mode: findings print a warning
and the run passes. Clear the backlog (below), then set the repository variable
`AUDIT_ENFORCE` to `true` (Settings > Secrets and variables > Actions >
Variables). From then on a finding fails the run. Do not leave it warn-only.

## When the audit is red

1. Read the log: each finding names the package, version and advisory ID.
2. **Fix it if you can.** Almost always a bump: update the dependency, rebuild, run the tests.
3. **Acknowledge it only if** it does not apply to us, or no fixed release exists. Add an `[[IgnoredVulns]]` entry to `osv-scanner.toml` with a `reason` and an `ignoreUntil` date **at most 90 days** ahead.
4. Never remove the audit to get a change out. A same-day hotfix still goes through: fix or acknowledge in the same PR.

If osv.dev is down the job fails rather than passing on unknown data. Re-run it.

## Renovate (bump PRs)

Inert until the **Renovate GitHub app** is installed on the repo (owner, once).

- Mondays before 06:00 UTC: one PR per ecosystem for minor and patch bumps, one for GitHub Actions (pinned to commit digests). Majors come as separate PRs.
- First day of the month: a lockfile maintenance PR for indirect packages.
- Packages with a known vulnerability get a PR at any time, labelled `security`.
- Normal bumps wait **14 days** after release (a bad release is usually pulled by then).
- No auto-merge.

Also turn on **Dependabot alerts** (Settings > Code security): they email you about advisories between Renovate runs.

## Quarterly review

Re-read every entry in `osv-scanner.toml`. Is a fixed version out now? Bump and delete the entry. Does the reason still hold?
