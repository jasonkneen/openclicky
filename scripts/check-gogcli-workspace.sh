#!/usr/bin/env bash
set -euo pipefail

if ! command -v gog >/dev/null 2>&1; then
  cat <<'EOF'
gog is not installed.

Install on macOS:
  brew install gogcli

Then configure local OAuth credentials:
  gog auth credentials ~/Downloads/client_secret_....json
  gog auth add you@example.com --services gmail,calendar,drive --readonly
EOF
  exit 1
fi

printf '== gog version ==\n'
gog --version

printf '\n== gog auth status ==\n'
gog auth status --json || true

printf '\n== gog accounts ==\n'
gog auth list || true

cat <<'EOF'

If credentials_exists is false, store a Desktop OAuth client JSON:
  gog auth credentials ~/Downloads/client_secret_....json

For a named Workspace client/domain:
  gog --client work auth credentials ~/Downloads/work-client.json --domain example.com

For least-privilege auth examples:
  gog auth add you@example.com --services gmail,drive --gmail-scope readonly --drive-scope readonly
  gog auth add you@example.com --services calendar,tasks --readonly
EOF
