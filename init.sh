#!/bin/bash
set -e

# Read the actual data dir path detected at build time
DETECTED_PATH=$(cat /opt/geoserver_data_dir_path.txt 2>/dev/null || echo "")
GEOSERVER_DATA_DIR="$DETECTED_PATH"
GEOSERVER_URL="http://localhost:8080/geoserver"
AUTH="$GEOSERVER_ADMIN_USER:$GEOSERVER_ADMIN_PASSWORD"
SHAPEFILE_DIR="$GEOSERVER_DATA_DIR/data/shapefiles"

echo "GeoServer data dir: $GEOSERVER_DATA_DIR"

# ── Step 1: Seed data_dir on first boot ──────────────────────────────────────
# The Render disk is mounted at the same path as the data_dir.
# On first deploy the disk is empty — seed it from the image backup.
if [ ! -f "$GEOSERVER_DATA_DIR/global.xml" ]; then
  echo "Disk is empty — seeding GeoServer data directory..."
  cp -r /opt/geoserver_data_dir_default/. "$GEOSERVER_DATA_DIR/"
  echo "Data directory seeded successfully."

  mkdir -p "$SHAPEFILE_DIR"

  if [ -d "/opt/geoserver_shapefiles" ]; then
    echo "Copying shapefiles to persistent disk..."
    cp -r /opt/geoserver_shapefiles/. "$SHAPEFILE_DIR/"
  fi
else
  echo "Persistent data directory already initialised — skipping seed."
  # Sync any new shapefiles added in latest deploy
  if [ -d "/opt/geoserver_shapefiles" ]; then
    echo "Syncing new shapefiles..."
    cp -rn /opt/geoserver_shapefiles/. "$SHAPEFILE_DIR/" 2>/dev/null || true
  fi
fi

# ── Step 2: Start GeoServer ───────────────────────────────────────────────────
echo "Starting GeoServer..."
/opt/startup.sh &

# ── Step 3: Wait for REST API ─────────────────────────────────────────────────
echo "Waiting for GeoServer REST API..."
for i in $(seq 1 90); do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" "$GEOSERVER_URL/rest/workspaces.json")
  if [ "$HTTP_CODE" = "200" ]; then
    echo "GeoServer REST API ready! (attempt $i)"
    break
  fi
  echo "Attempt $i: not ready (HTTP $HTTP_CODE), waiting 5s..."
  sleep 5
done

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" "$GEOSERVER_URL/rest/workspaces.json")
if [ "$HTTP_CODE" != "200" ]; then
  echo "ERROR: GeoServer REST API did not become ready. Exiting."
  exit 1
fi

# ── Step 4: Proxy base URL ────────────────────────────────────────────────────
if [ -n "$RENDER_EXTERNAL_URL" ]; then
  echo "Setting proxy base URL..."
  curl -s -u "$AUTH" -X PUT -H "Content-Type: application/xml" \
    -d "<global><proxyBaseUrl>${RENDER_EXTERNAL_URL}/geoserver/</proxyBaseUrl></global>" \
    "$GEOSERVER_URL/rest/settings" || echo "Warning: could not set proxy base URL"
fi

# ── Step 5: Create workspace ──────────────────────────────────────────────────
WORKSPACE_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" \
  "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE.json")

if [ "$WORKSPACE_HTTP" = "200" ]; then
  echo "Workspace '$GEOSERVER_WORKSPACE' already exists — skipping."
else
  echo "Creating workspace: $GEOSERVER_WORKSPACE"
  CREATE_WS=$(curl -s -o /tmp/ws_response.txt -w "%{http_code}" -u "$AUTH" \
    -X POST -H "Content-Type: application/json" \
    -d "{\"workspace\":{\"name\":\"$GEOSERVER_WORKSPACE\"}}" \
    "$GEOSERVER_URL/rest/workspaces")
  if [ "$CREATE_WS" = "201" ]; then
    echo "Workspace '$GEOSERVER_WORKSPACE' created and persisted to disk."
  else
    echo "ERROR: Failed to create workspace (HTTP $CREATE_WS):"
    cat /tmp/ws_response.txt
    exit 1
  fi
fi

# ── Step 6: PostGIS datastore ─────────────────────────────────────────────────
if [ -n "$POSTGIS_HOST" ] && [ -n "$POSTGIS_DB" ]; then
  STORE_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" \
    "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/postgis.json")

  if [ "$STORE_HTTP" = "200" ]; then
    echo "PostGIS store already exists — skipping."
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
      echo "PostGIS datastore created."
    else
      echo "ERROR: Failed to create PostGIS datastore (HTTP $CREATE_STORE):"
      cat /tmp/store_response.txt
    fi
  fi

  echo "Publishing PostGIS layers..."
  FEATURE_TYPES=$(curl -s -u "$AUTH" \
    "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/postgis/featuretypes.json?list=available" \
    | jq -r '.list.string[]? // empty' 2>/dev/null || true)

  for LAYER in $FEATURE_TYPES; do
    LAYER_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" \
      "$GEOSERVER_URL/rest/layers/$GEOSERVER_WORKSPACE:$LAYER.json")
    if [ "$LAYER_HTTP" != "200" ]; then
      echo "Publishing layer: $LAYER"
      curl -s -u "$AUTH" -X POST -H "Content-Type: application/json" \
        -d "{\"featureType\":{\"name\":\"$LAYER\",\"nativeName\":\"$LAYER\",\"srs\":\"EPSG:4326\"}}" \
        "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/postgis/featuretypes" \
        || echo "Warning: could not publish layer $LAYER"
    else
      echo "Layer '$LAYER' already exists — skipping."
    fi
  done
else
  echo "POSTGIS_HOST not set — skipping PostGIS configuration."
fi

# ── Step 7: Publish shapefiles ────────────────────────────────────────────────
if [ -d "$SHAPEFILE_DIR" ]; then
  echo "Publishing shapefiles..."
  for SHP in "$SHAPEFILE_DIR"/*.shp; do
    [ -f "$SHP" ] || continue
    LAYER=$(basename "$SHP" .shp)
    STORE_NAME="shp_$LAYER"

    SHPSTORE_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" \
      "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/$STORE_NAME.json")

    if [ "$SHPSTORE_HTTP" != "200" ]; then
      echo "Creating shapefile store: $STORE_NAME"
      curl -s -u "$AUTH" -X POST -H "Content-Type: application/json" \
        -d "{
          \"dataStore\": {
            \"name\": \"$STORE_NAME\",
            \"connectionParameters\": {
              \"entry\": [
                {\"@key\": \"url\",     \"$\": \"file:data/shapefiles/${LAYER}.shp\"},
                {\"@key\": \"charset\", \"$\": \"UTF-8\"}
              ]
            }
          }
        }" \
        "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores" \
        || echo "Warning: could not create store $STORE_NAME"
    else
      echo "Store '$STORE_NAME' already exists — skipping."
    fi

    LAYER_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" \
      "$GEOSERVER_URL/rest/layers/$GEOSERVER_WORKSPACE:$LAYER.json")

    if [ "$LAYER_HTTP" != "200" ]; then
      echo "Publishing shapefile layer: $LAYER"
      curl -s -u "$AUTH" -X POST -H "Content-Type: application/json" \
        -d "{\"featureType\":{\"name\":\"$LAYER\",\"nativeName\":\"$LAYER\",\"srs\":\"EPSG:4326\"}}" \
        "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/$STORE_NAME/featuretypes" \
        || echo "Warning: could not publish layer $LAYER"
    else
      echo "Layer '$LAYER' already exists — skipping."
    fi
  done
else
  echo "No shapefiles directory found — skipping."
fi

echo "========================================"
echo "GeoServer initialisation complete."
echo "All config persisted on Render Disk."
echo "========================================"

wait
