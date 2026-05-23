#!/bin/bash
set -e

/opt/startup.sh &

GEOSERVER_URL="http://localhost:8080/geoserver"
AUTH="$GEOSERVER_ADMIN_USER:$GEOSERVER_ADMIN_PASSWORD"

echo "Waiting for GeoServer to start..."
for i in $(seq 1 60); do
  if curl -sf -u "$AUTH" "$GEOSERVER_URL/rest/about/status.xml" > /dev/null 2>&1; then
    echo "GeoServer is ready!"
    break
  fi
  echo "  attempt $i/60..."
  sleep 5
done

# Set proxy base URL (required before any further config on Render)
if [ -n "$RENDER_EXTERNAL_URL" ]; then
  echo "Setting proxy base URL to ${RENDER_EXTERNAL_URL}/geoserver/"
  curl -sf -u "$AUTH" -X PUT \
    -H "Content-Type: application/xml" \
    -d "<global><settings><proxyBaseUrl>${RENDER_EXTERNAL_URL}/geoserver/</proxyBaseUrl></settings></global>" \
    "$GEOSERVER_URL/rest/settings" || echo "Warning: could not set proxy base URL"
fi

if [ -n "$POSTGIS_HOST" ] && [ -n "$POSTGIS_DB" ]; then
  echo "Configuring PostGIS store..."

  # Create workspace if needed
  WORKSPACE_EXISTS=$(curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" \
    "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE.json")
  if [ "$WORKSPACE_EXISTS" != "200" ]; then
    echo "Creating workspace: $GEOSERVER_WORKSPACE"
    curl -sf -u "$AUTH" -X POST \
      -H "Content-Type: application/json" \
      -d "{\"workspace\":{\"name\":\"$GEOSERVER_WORKSPACE\"}}" \
      "$GEOSERVER_URL/rest/workspaces"
  else
    echo "Workspace $GEOSERVER_WORKSPACE already exists, skipping."
  fi

  # Create datastore if needed
  STORE_EXISTS=$(curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" \
    "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/postgis.json")
  if [ "$STORE_EXISTS" != "200" ]; then
    echo "Creating PostGIS data store..."
    curl -sf -u "$AUTH" -X POST \
      -H "Content-Type: application/json" \
      -d "{
        \"dataStore\": {
          \"name\": \"postgis\",
          \"type\": \"PostGIS\",
          \"enabled\": true,
          \"connectionParameters\": {
            \"entry\": [
              {\"@key\":\"host\",     \"$\":\"$POSTGIS_HOST\"},
              {\"@key\":\"port\",     \"$\":\"$POSTGIS_PORT\"},
              {\"@key\":\"database\", \"$\":\"$POSTGIS_DB\"},
              {\"@key\":\"user\",     \"$\":\"$POSTGIS_USER\"},
              {\"@key\":\"passwd\",   \"$\":\"$POSTGIS_PASSWORD\"},
              {\"@key\":\"dbtype\",   \"$\":\"postgis\"},
              {\"@key\":\"schema\",   \"$\":\"$POSTGIS_SCHEMA\"}
            ]
          }
        }
      }" \
      "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores"
  else
    echo "PostGIS store already exists, skipping."
  fi

  # Publish available (unpublished) feature types
  echo "Publishing layers from PostGIS tables..."
  AVAILABLE=$(curl -sf -u "$AUTH" \
    "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/postgis/featuretypes.json?list=available" \
    | grep -oP '"string":\s*"\K[^"]+' || true)

  for LAYER in $AVAILABLE; do
    echo "Publishing layer: $LAYER"
    curl -sf -u "$AUTH" -X POST \
      -H "Content-Type: application/json" \
      -d "{\"featureType\":{\"name\":\"$LAYER\",\"nativeName\":\"$LAYER\"}}" \
      "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/postgis/featuretypes" \
      || echo "Warning: could not publish $LAYER"
  done
else
  echo "POSTGIS_HOST not set — skipping PostGIS auto-configuration."
fi

echo "Startup complete."
wait