#!/bin/bash
# Fetches new FalconMail diagnostics and prints them grouped by problem, newest first.
# Needs only python3. Run with -h for the options; see tools/diagnostics/README.md.
set -euo pipefail
exec python3 "$(cd "$(dirname "$0")" && pwd)/fetch_reports.py" "$@"
