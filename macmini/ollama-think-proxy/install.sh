#!/bin/bash
# Install or update ollama-think-proxy as a launchd agent on the Mac mini. Idempotent: re-run after any change.
# Run it ON the Mac mini, as the user Ollama runs as:  bash macmini/ollama-think-proxy/install.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
label=pl.sudops.ollama-think-proxy
dest="$HOME/Library/Application Support/ollama-think-proxy"
plist="$HOME/Library/LaunchAgents/$label.plist"

py="$(command -v python3)" || { echo "python3 not found (install the Xcode command line tools)" >&2; exit 1; }
"$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 7) else 1)' \
  || { echo "$py is older than Python 3.7" >&2; exit 1; }

mkdir -p "$dest" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp "$here/ollama-think-proxy.py" "$dest/ollama-think-proxy.py"
sed -e "s|__PYTHON__|$py|g" -e "s|__DEST__|$dest|g" -e "s|__HOME__|$HOME|g" \
  "$here/$label.plist.in" > "$plist"
plutil -lint "$plist" >/dev/null

# Reload so a changed script or plist takes effect.
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null && sleep 2 || true
launchctl bootstrap "gui/$(id -u)" "$plist"
sleep 2

if curl -fsS --max-time 5 http://127.0.0.1:11435/api/version; then
  echo
  echo "ok: ollama-think-proxy answers on :11435 (log: ~/Library/Logs/ollama-think-proxy.log)"
else
  echo "proxy not answering on :11435; see ~/Library/Logs/ollama-think-proxy.log and: launchctl print gui/$(id -u)/$label" >&2
  exit 1
fi
