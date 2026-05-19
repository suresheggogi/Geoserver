#!/bin/bash
set -e

# Start GeoServer in the background
/opt/startup.sh &

GEOSERVER_URL="http://localhost:8080/geoserver"
AUTH="$GEOSERVER_ADMIN_USER:$GEOSERVER_ADMIN_PASSWORD"
SHAPEFILE_DIR="/opt/geoserver/data_dir/data/shapefiles"

echo "Waiting for GeoServer REST API to be fully ready..."
for i in $(seq 1 90); do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" "$GEOSERVER_URL/rest/workspaces.json")
  if [ "$HTTP_CODE" = "200" ]; then
    echo "GeoServer REST API is ready! (attempt $i)"
    break
  fi
  echo "Attempt $i: REST API not ready yet (HTTP $HTTP_CODE), waiting 5s..."
  sleep 5
done

# Final check — abort if still not ready
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" "$GEOSERVER_URL/rest/workspaces.json")
if [ "$HTTP_CODE" != "200" ]; then
  echo "ERROR: GeoServer REST API did not become ready in time (HTTP $HTTP_CODE). Exiting."
  exit 1
fi

# ── Proxy base URL ────────────────────────────────────────────────────────────
if [ -n "$RENDER_EXTERNAL_URL" ]; then
  echo "Setting proxy base URL to $RENDER_EXTERNAL_URL/geoserver/"
  curl -s -u "$AUTH" -X PUT -H "Content-Type: application/xml" \
    -d "<global><proxyBaseUrl>${RENDER_EXTERNAL_URL}/geoserver/</proxyBaseUrl></global>" \
    "$GEOSERVER_URL/rest/settings" || echo "Warning: could not set proxy base URL"
fi

# ── Create workspace ──────────────────────────────────────────────────────────
echo "Checking workspace: $GEOSERVER_WORKSPACE"
WORKSPACE_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" \
  "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE.json")

if [ "$WORKSPACE_HTTP" = "200" ]; then
  echo "Workspace '$GEOSERVER_WORKSPACE' already exists, skipping."
else
  echo "Creating workspace: $GEOSERVER_WORKSPACE"
  CREATE_WS=$(curl -s -o /tmp/ws_response.txt -w "%{http_code}" -u "$AUTH" \
    -X POST -H "Content-Type: application/json" \
    -d "{\"workspace\":{\"name\":\"$GEOSERVER_WORKSPACE\"}}" \
    "$GEOSERVER_URL/rest/workspaces")
  if [ "$CREATE_WS" = "201" ]; then
    echo "Workspace '$GEOSERVER_WORKSPACE' created successfully."
  else
    echo "ERROR: Failed to create workspace (HTTP $CREATE_WS):"
    cat /tmp/ws_response.txt
    exit 1
  fi
fi

# ── PostGIS datastore ─────────────────────────────────────────────────────────
if [ -n "$POSTGIS_HOST" ] && [ -n "$POSTGIS_DB" ]; then
  echo "Checking PostGIS datastore..."
  STORE_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" \
    "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/postgis.json")

  if [ "$STORE_HTTP" = "200" ]; then
    echo "PostGIS store already exists, skipping."
  else
    echo "Creating PostGIS datastore..."
    CREATE_STORE=$(curl -s -o /tmp/store_response.txt -w "%{http_code}" -u "$AUTH" \
      -X POST -H "Content-Type: application/json" \
      -d "{
        \"dataStore\": {
          \"name\": \"postgis\",
          \"connectionParameters\": {
            \"entry\": [
              {\"@key\": \"host\",     \"$\": \"$POSTGIS_HOST\"},
              {\"@key\": \"port\",     \"$\": \"$POSTGIS_PORT\"},
              {\"@key\": \"database\", \"$\": \"$POSTGIS_DB\"},
              {\"@key\": \"user\",     \"$\": \"$POSTGIS_USER\"},
              {\"@key\": \"passwd\",   \"$\": \"$POSTGIS_PASSWORD\"},
              {\"@key\": \"dbtype\",   \"$\": \"postgis\"},
              {\"@key\": \"schema\",   \"$\": \"$POSTGIS_SCHEMA\"},
              {\"@key\": \"Expose primary keys\", \"$\": \"true\"}
            ]
          }
        }
      }" \
      "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores")

    if [ "$CREATE_STORE" = "201" ]; then
      echo "PostGIS datastore created successfully."
    else
      echo "ERROR: Failed to create PostGIS datastore (HTTP $CREATE_STORE):"
      cat /tmp/store_response.txt
      # Non-fatal — continue to shapefiles
    fi
  fi

  echo "Publishing layers from PostGIS tables..."
  FEATURE_TYPES=$(curl -s -u "$AUTH" \
    "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/postgis/featuretypes.json?list=available" \
    | jq -r '.list.string[]? // empty' 2>/dev/null || true)

  for LAYER in $FEATURE_TYPES; do
    LAYER_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" \
      "$GEOSERVER_URL/rest/layers/$GEOSERVER_WORKSPACE:$LAYER.json")
    if [ "$LAYER_HTTP" = "200" ]; then
      echo "Layer '$LAYER' already published, skipping."
    else
      echo "Publishing PostGIS layer: $LAYER"
      curl -s -u "$AUTH" -X POST -H "Content-Type: application/json" \
        -d "{\"featureType\":{\"name\":\"$LAYER\",\"nativeName\":\"$LAYER\",\"srs\":\"EPSG:4326\"}}" \
        "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/postgis/featuretypes" \
        || echo "Warning: could not publish layer $LAYER"
    fi
  done
else
  echo "POSTGIS_HOST not set — skipping PostGIS configuration."
fi

# ── Publish shapefiles ────────────────────────────────────────────────────────
if [ -d "$SHAPEFILE_DIR" ]; then
  echo "Publishing shapefiles from $SHAPEFILE_DIR ..."

  for SHP in "$SHAPEFILE_DIR"/*.shp; do
    [ -f "$SHP" ] || continue
    LAYER=$(basename "$SHP" .shp)
    STORE_NAME="shp_$LAYER"

    echo "Processing shapefile: $LAYER"

    # Create a shapefile datastore for this .shp
    SHPSTORE_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" \
      "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/$STORE_NAME.json")

    if [ "$SHPSTORE_HTTP" = "200" ]; then
      echo "Shapefile store '$STORE_NAME' already exists, skipping."
    else
      echo "Creating shapefile store for: $LAYER"
      CREATE_SHP=$(curl -s -o /tmp/shp_response.txt -w "%{http_code}" -u "$AUTH" \
        -X POST -H "Content-Type: application/json" \
        -d "{
          \"dataStore\": {
            \"name\": \"$STORE_NAME\",
            \"connectionParameters\": {
              \"entry\": [
                {\"@key\": \"url\",        \"$\": \"file:data/shapefiles/${LAYER}.shp\"},
                {\"@key\": \"memory mapped buffer\", \"$\": \"false\"},
                {\"@key\": \"charset\",    \"$\": \"UTF-8\"}
              ]
            }
          }
        }" \
        "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores")

      if [ "$CREATE_SHP" = "201" ]; then
        echo "Shapefile store '$STORE_NAME' created."
      else
        echo "ERROR: Failed to create shapefile store (HTTP $CREATE_SHP):"
        cat /tmp/shp_response.txt
        continue
      fi
    fi

    # Publish the layer from the shapefile store
    LAYER_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" \
      "$GEOSERVER_URL/rest/layers/$GEOSERVER_WORKSPACE:$LAYER.json")

    if [ "$LAYER_HTTP" = "200" ]; then
      echo "Layer '$LAYER' already published, skipping."
    else
      echo "Publishing shapefile layer: $LAYER"
      curl -s -o /tmp/shplayer_response.txt -u "$AUTH" \
        -X POST -H "Content-Type: application/json" \
        -d "{\"featureType\":{\"name\":\"$LAYER\",\"nativeName\":\"$LAYER\",\"srs\":\"EPSG:4326\"}}" \
        "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/$STORE_NAME/featuretypes" \
        || echo "Warning: could not publish shapefile layer $LAYER"
      echo "Layer '$LAYER' published."
    fi
  done
else
  echo "No shapefiles directory found at $SHAPEFILE_DIR, skipping."
fi

echo "========================================"
echo "GeoServer initialisation complete."
echo "========================================"

# Keep the container alive (wait for background GeoServer process)
wait
