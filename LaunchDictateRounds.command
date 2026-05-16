#!/bin/bash
# ─── DictateRounds Launcher ───
# Double-click this file to start DictateRounds in Chrome

PORT=8091
DIR="$(cd "$(dirname "$0")" && pwd)"

# Check if port is already in use
if lsof -i :$PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
  /usr/bin/open -a "/Applications/Google Chrome.app" "http://localhost:$PORT/DictateRounds.html"
  exit 0
fi

# Start Python HTTP server in the background
cd "$DIR"
python3 -m http.server $PORT &>/dev/null &
SERVER_PID=$!

# Wait for server to be ready
sleep 1

# Open in Chrome using the full application path
/usr/bin/open -a "/Applications/Google Chrome.app" "http://localhost:$PORT/DictateRounds.html"

echo ""
echo "  ╔═══════════════════════════════════════╗"
echo "  ║  DictateRounds running on port $PORT  ║"
echo "  ║  Press Ctrl+C or close to stop        ║"
echo "  ╚═══════════════════════════════════════╝"
echo ""

wait $SERVER_PID
