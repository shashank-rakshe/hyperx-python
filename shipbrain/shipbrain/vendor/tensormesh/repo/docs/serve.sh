#!/usr/bin/env bash
# Serve the built docs locally with no-cache headers, so the browser always
# picks up the latest rebuild. Usage:
#   ./serve.sh           # port 8000
#   ./serve.sh 8001      # custom port
set -euo pipefail

PORT="${1:-8000}"
DOCS_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$DOCS_DIR/_build/html"

if [ ! -d "$BUILD_DIR" ]; then
    echo "error: $BUILD_DIR does not exist. Run 'make html-all' first." >&2
    exit 1
fi

cd "$BUILD_DIR"

echo "Serving $BUILD_DIR"
echo "Host:  $(hostname)"
echo "Port:  $PORT"
echo "URL:   http://localhost:$PORT (English)"
echo "       http://localhost:$PORT/zh/ (Chinese)"
echo
echo "From your laptop, run:"
echo "  ssh -N -L $PORT:$(hostname):$PORT <your-euler-host>"
echo
echo "Press Ctrl-C to stop."
echo

exec python -c "
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import sys
class NoCacheHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0')
        self.send_header('Pragma', 'no-cache')
        self.send_header('Expires', '0')
        super().end_headers()
ThreadingHTTPServer(('', int(sys.argv[1])), NoCacheHandler).serve_forever()
" "$PORT"
