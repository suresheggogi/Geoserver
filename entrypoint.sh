#!/bin/bash
set -euo pipefail

if [ -f /opt/init.sh ]; then
  echo "Starting GeoServer init script..."
  bash /opt/init.sh &
fi

<<<<<<< HEAD
exec bash /opt/startup.sh
=======
exec bash /opt/startup.sh
>>>>>>> 40d125d7e2fca83390313edfcc7b5538c3b5b9b1
