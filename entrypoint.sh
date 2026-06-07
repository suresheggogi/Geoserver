#!/bin/bash
set -euo pipefail

if [ -f /opt/init.sh ]; then
  echo "Starting GeoServer init script..."
  bash /opt/init.sh &
fi

exec bash /opt/startup.sh
