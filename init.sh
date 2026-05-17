#!/bin/bash
set -e

GEOSERVER_URL="http://localhost:8080/geoserver"
AUTH="$GEOSERVER_ADMIN_USER:$GEOSERVER_ADMIN_PASSWORD"

echo "Starting GeoServer..."
/opt/startup.sh &

echo "Waiting for GeoServer to start..."
for i in $(seq 1 60); do
  if curl -sf -u "$AUTH" "$GEOSERVER_URL/rest/about/status.xml" > /dev/null 2>&1; then
    echo "GeoServer is ready!"
    break
  fi
  echo "Attempt $i/60 — waiting 5s..."
  sleep 5
done

# ✅ Set proxy base URL
if [ -n "$RENDER_EXTERNAL_URL" ]; then
  echo "Setting proxy base URL to $RENDER_EXTERNAL_URL/geoserver/"
  curl -sf -u "$AUTH" -X PUT -H "Content-Type: application/xml" \
    -d "<global><proxyBaseUrl>${RENDER_EXTERNAL_URL}/geoserver/</proxyBaseUrl></global>" \
    "$GEOSERVER_URL/rest/settings" || echo "Warning: could not set proxy base URL"
fi

#  Create workspace FIRST (needed for both shapefile and PostGIS)
WORKSPACE_EXISTS=$(curl -sf -u "$AUTH" \
  "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE.xml" \
  -o /dev/null -w "%{http_code}")
if [ "$WORKSPACE_EXISTS" != "200" ]; then
  echo "Creating workspace: $GEOSERVER_WORKSPACE"
  curl -sf -u "$AUTH" -X POST -H "Content-Type: application/xml" \
    -d "<workspace><name>$GEOSERVER_WORKSPACE</name></workspace>" \
    "$GEOSERVER_URL/rest/workspaces"
else
  echo "Workspace $GEOSERVER_WORKSPACE already exists, skipping."
fi

#  Download shapefile from S3 only if URL is provided
if [ -n "$SHAPEFILE_S3_URL" ] && [ -n "$SHAPEFILE_NAME" ]; then
  echo "Downloading shapefile from S3: $SHAPEFILE_NAME"
  mkdir -p /opt/geoserver_data/shapefiles
  curl -fL -o "/opt/geoserver_data/shapefiles/${SHAPEFILE_NAME}.zip" "$SHAPEFILE_S3_URL"
fi

# Register and publish shapefile if available
if [ -n "$SHAPEFILE_NAME" ]; then
  SHAPEFILE_ZIP="/opt/geoserver_data/shapefiles/${SHAPEFILE_NAME}.zip"
  if [ -f "$SHAPEFILE_ZIP" ]; then
    echo "Registering shapefile store: $SHAPEFILE_NAME"
    curl -sf -u "$AUTH" -X PUT \
      -H "Content-Type: application/zip" \
      --data-binary @"$SHAPEFILE_ZIP" \
      "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/${SHAPEFILE_NAME}/file.shp"

    echo "Publishing shapefile layer: $SHAPEFILE_NAME"
    curl -sf -u "$AUTH" -X POST -H "Content-Type: application/xml" \
      -d "<featureType><name>${SHAPEFILE_NAME}</name></featureType>" \
      "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/${SHAPEFILE_NAME}/featuretypes" \
      || echo "Warning: layer may already exist or publish failed"
  else
    echo "Warning: Shapefile ZIP not found at $SHAPEFILE_ZIP"
  fi
fi

#  PostGIS configuration
if [ -n "$POSTGIS_HOST" ] && [ -n "$POSTGIS_DB" ]; then
  echo "Configuring PostGIS store..."

  STORE_EXISTS=$(curl -sf -u "$AUTH" \
    "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/postgis.xml" \
    -o /dev/null -w "%{http_code}")
  if [ "$STORE_EXISTS" != "200" ]; then
    echo "Creating PostGIS data store..."
    curl -sf -u "$AUTH" -X POST -H "Content-Type: application/xml" \
      -d "<dataStore><name>postgis</name><connectionParameters>
        <host>$POSTGIS_HOST</host>
        <port>$POSTGIS_PORT</port>
        <database>$POSTGIS_DB</database>
        <user>$POSTGIS_USER</user>
        <passwd>$POSTGIS_PASSWORD</passwd>
        <dbtype>postgis</dbtype>
        <schema>$POSTGIS_SCHEMA</schema>
      </connectionParameters></dataStore>" \
      "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores"
  else
    echo "PostGIS store already exists, skipping."
  fi

  echo "Publishing layers from PostGIS tables..."
  LAYER_NAMES=$(curl -sf -u "$AUTH" \
    "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/postgis/featuretypes.xml" \
    | grep -oP '<name>\K[^<]+' || true)

  for LAYER in $LAYER_NAMES; do
    LAYER_EXISTS=$(curl -sf -u "$AUTH" \
      "$GEOSERVER_URL/rest/layers/$GEOSERVER_WORKSPACE:$LAYER.xml" \
      -o /dev/null -w "%{http_code}")
    if [ "$LAYER_EXISTS" != "200" ]; then
      echo "Publishing layer: $LAYER"
      curl -sf -u "$AUTH" -X POST -H "Content-Type: application/xml" \
        -d "<featureType><name>$LAYER</name><nativeName>$LAYER</nativeName></featureType>" \
        "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/postgis/featuretypes"
    else
      echo "Layer $LAYER already exists, skipping."
    fi
  done
else
  echo "POSTGIS_HOST not set — skipping PostGIS auto-configuration."
fi

echo "Startup complete."
wait
