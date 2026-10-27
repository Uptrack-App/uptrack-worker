#!/usr/bin/env bash
# security-audit.sh: check every lockfile of this repo against the OSV
# advisory database (osv.dev: RustSec, GitHub advisories, Hex, npm, pub, ...).
#
# CI runs it (.github/workflows/audit.yml); run it by hand before a deploy:
#   scripts/security-audit.sh
#
# The scanner is pinned by version and SHA-256, so a hijacked release or a
# moved tag cannot run in CI or on your laptop. Acknowledged advisories live in
# osv-scanner.toml, each with a reason and an ignoreUntil date
# (docs/SECURITY-DEPENDENCIES.md).
#
# AUDIT_ENFORCE=true makes findings fail the run. Without it findings are
# printed as warnings and the run passes: that is only for a repo that still
# has a backlog. Once the backlog is clear, set the repo variable
# AUDIT_ENFORCE=true (Settings > Secrets and variables > Actions > Variables).
# If osv.dev is down the run fails: it never passes on unknown data.
set -euo pipefail

OSV_VERSION=v2.7.0
LOCKFILES=(mix.lock)

cd "$(dirname "$0")/.."

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    asset=osv-scanner_linux_amd64
    sha=160c6253e2922e9e0a6a9771c5c4c40a4b3c6090b34a3cdd5e80c96cc2e4218b ;;
  Darwin-arm64)
    asset=osv-scanner_darwin_arm64
    sha=d4926ef8da134332543be276dff157e4c170f99ad91fc48e89448a8816bdf70b ;;
  *)
    echo "security-audit: no pinned osv-scanner for $(uname -s)-$(uname -m)" >&2
    exit 2 ;;
esac

dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/osv-scanner-$OSV_VERSION"
bin="$dir/$asset"
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

if [ ! -x "$bin" ] || [ "$(sha256 "$bin")" != "$sha" ]; then
  mkdir -p "$dir"
  curl -fsSL -o "$bin" "https://github.com/google/osv-scanner/releases/download/$OSV_VERSION/$asset"
  if [ "$(sha256 "$bin")" != "$sha" ]; then
    echo "security-audit: $asset does not match the pinned SHA-256" >&2
    rm -f "$bin"
    exit 2
  fi
  chmod +x "$bin"
fi

args=(scan source --config osv-scanner.toml)
for f in "${LOCKFILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "security-audit: $f is listed in scripts/security-audit.sh but does not exist" >&2
    exit 2
  fi
  args+=(-L "$f")
done

status=0
"$bin" "${args[@]}" || status=$?

# osv-scanner exits 1 when it found vulnerabilities; any other non-zero code is
# an error (network, parse) and always fails.
if [ "$status" -eq 1 ] && [ "${AUDIT_ENFORCE:-}" != "true" ]; then
  echo "::warning::known vulnerabilities in the lockfiles (not enforced yet: set AUDIT_ENFORCE=true once the backlog is cleared; see docs/SECURITY-DEPENDENCIES.md)"
  exit 0
fi
exit "$status"
