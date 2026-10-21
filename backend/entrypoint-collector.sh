#!/bin/sh
# Collector entrypoint: the Railway volume mounts over /data as root — make it the app user's
# before exec'ing the service. The collector is read-only elsewhere; root is dropped immediately.
set -e
chown node:node /data
exec su node -c "node /app/dist/collect-nav-cli.js serve"