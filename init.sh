#!/bin/bash
set -e

# ── Config ────────────────────────────────────────────────────────────────────
DETECTED_PATH=$(cat /opt/geoserver_data_dir_path.txt 2>/dev/null || echo "")
GEOSERVER_DATA_DIR="$DETECTED_PATH"
GEOSERVER_URL="http://localhost:8080/geoserver"
AUTH="$GEOSERVER_ADMIN_USER:$GEOSERVER_ADMIN_PASSWORD"
SHAPEFILE_DIR="$GEOSERVER_DATA_DIR/data/shapefiles"
LAYER_NAME="Siricilla"
STORE_NAME="shp_Siricilla"

echo "================================================"
echo "GeoServer data dir : $GEOSERVER_DATA_DIR"
echo "Shapefile dir      : $SHAPEFILE_DIR"
echo "Layer              : $LAYER_NAME"
echo "================================================"

# ── Step 1: Seed data_dir on first boot ───────────────────────────────────────
if [ ! -f "$GEOSERVER_DATA_DIR/global.xml" ]; then
  echo "[Step 1] Disk is empty — seeding GeoServer data directory..."
  cp -r /opt/geoserver_data_dir_default/. "$GEOSERVER_DATA_DIR/"
  echo "[Step 1] Data directory seeded."

  mkdir -p "$SHAPEFILE_DIR"
  if [ -d "/opt/geoserver_shapefiles" ]; then
    echo "[Step 1] Copying Siricilla shapefile to persistent disk..."
    cp -r /opt/geoserver_shapefiles/. "$SHAPEFILE_DIR/"
    echo "[Step 1] Shapefiles copied:"
    ls -lh "$SHAPEFILE_DIR/"
  fi
else
  echo "[Step 1] Persistent data directory already initialised — skipping seed."
  # Always sync shapefiles so new deploys pick up updated files
  if [ -d "/opt/geoserver_shapefiles" ]; then
    echo "[Step 1] Syncing shapefiles (new files only)..."
    cp -rn /opt/geoserver_shapefiles/. "$SHAPEFILE_DIR/" 2>/dev/null || true
    echo "[Step 1] Shapefiles present:"
    ls -lh "$SHAPEFILE_DIR/"
  fi
fi

# ── Step 2: Start GeoServer ───────────────────────────────────────────────────
echo "[Step 2] Starting GeoServer..."
/opt/startup.sh &
GEOSERVER_PID=$!

# ── Step 3: Wait for REST API (up to 7.5 min) ────────────────────────────────
echo "[Step 3] Waiting for GeoServer REST API..."
for i in $(seq 1 90); do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "$AUTH" "$GEOSERVER_URL/rest/workspaces.json")
  if [ "$HTTP_CODE" = "200" ]; then
    echo "[Step 3] REST API ready after $i attempts."
    break
  fi
  echo "[Step 3] Attempt $i/90: HTTP $HTTP_CODE — retrying in 5s..."
  sleep 5
done

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "$AUTH" "$GEOSERVER_URL/rest/workspaces.json")
if [ "$HTTP_CODE" != "200" ]; then
  echo "ERROR: GeoServer REST API did not become ready. Exiting."
  exit 1
fi

# ── Step 4: Proxy base URL ────────────────────────────────────────────────────
if [ -n "$RENDER_EXTERNAL_URL" ]; then
  echo "[Step 4] Setting proxy base URL to ${RENDER_EXTERNAL_URL}/geoserver/"
  curl -s -u "$AUTH" -X PUT -H "Content-Type: application/xml" \
    -d "<global><settings><proxyBaseUrl>${RENDER_EXTERNAL_URL}/geoserver/</proxyBaseUrl></settings></global>" \
    "$GEOSERVER_URL/rest/settings" \
    || echo "[Step 4] Warning: could not set proxy base URL"
else
  echo "[Step 4] RENDER_EXTERNAL_URL not set — skipping proxy base URL."
fi

# ── Step 5: Create workspace ──────────────────────────────────────────────────
echo "[Step 5] Checking workspace '$GEOSERVER_WORKSPACE'..."
WS_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "$AUTH" "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE.json")

if [ "$WS_HTTP" = "200" ]; then
  echo "[Step 5] Workspace '$GEOSERVER_WORKSPACE' already exists — skipping."
else
  echo "[Step 5] Creating workspace '$GEOSERVER_WORKSPACE'..."
  CREATE_WS=$(curl -s -o /tmp/ws_resp.txt -w "%{http_code}" \
    -u "$AUTH" -X POST -H "Content-Type: application/json" \
    -d "{\"workspace\":{\"name\":\"$GEOSERVER_WORKSPACE\"}}" \
    "$GEOSERVER_URL/rest/workspaces")
  if [ "$CREATE_WS" = "201" ]; then
    echo "[Step 5] Workspace '$GEOSERVER_WORKSPACE' created."
  else
    echo "ERROR: Failed to create workspace (HTTP $CREATE_WS):"
    cat /tmp/ws_resp.txt
    exit 1
  fi
fi

# ── Step 6: PostGIS datastore (optional) ─────────────────────────────────────
if [ -n "$POSTGIS_HOST" ] && [ -n "$POSTGIS_DB" ]; then
  echo "[Step 6] Checking PostGIS datastore..."
  PG_STORE_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "$AUTH" \
    "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/postgis.json")

  if [ "$PG_STORE_HTTP" = "200" ]; then
    echo "[Step 6] PostGIS store already exists — skipping."
  else
    echo "[Step 6] Creating PostGIS datastore..."
    CREATE_PG=$(curl -s -o /tmp/pg_resp.txt -w "%{http_code}" \
      -u "$AUTH" -X POST -H "Content-Type: application/json" \
      -d "{
        \"dataStore\": {
          \"name\": \"postgis\",
          \"connectionParameters\": {
            \"entry\": [
              {\"@key\": \"host\",                \"$\": \"$POSTGIS_HOST\"},
              {\"@key\": \"port\",                \"$\": \"$POSTGIS_PORT\"},
              {\"@key\": \"database\",            \"$\": \"$POSTGIS_DB\"},
              {\"@key\": \"user\",                \"$\": \"$POSTGIS_USER\"},
              {\"@key\": \"passwd\",              \"$\": \"$POSTGIS_PASSWORD\"},
              {\"@key\": \"dbtype\",              \"$\": \"postgis\"},
              {\"@key\": \"schema\",              \"$\": \"$POSTGIS_SCHEMA\"},
              {\"@key\": \"Expose primary keys\", \"$\": \"true\"}
            ]
          }
        }
      }" \
      "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores")
    if [ "$CREATE_PG" = "201" ]; then
      echo "[Step 6] PostGIS datastore created."
    else
      echo "[Step 6] WARNING: Failed to create PostGIS store (HTTP $CREATE_PG):"
      cat /tmp/pg_resp.txt
    fi
  fi

  echo "[Step 6] Publishing PostGIS layers..."
  FEATURE_TYPES=$(curl -s -u "$AUTH" \
    "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/postgis/featuretypes.json?list=available" \
    | jq -r '.list.string[]? // empty' 2>/dev/null || true)

  for PG_LAYER in $FEATURE_TYPES; do
    PG_LAYER_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
      -u "$AUTH" \
      "$GEOSERVER_URL/rest/layers/$GEOSERVER_WORKSPACE:$PG_LAYER.json")
    if [ "$PG_LAYER_HTTP" != "200" ]; then
      echo "[Step 6] Publishing PostGIS layer: $PG_LAYER"
      curl -s -u "$AUTH" -X POST -H "Content-Type: application/json" \
        -d "{\"featureType\":{\"name\":\"$PG_LAYER\",\"nativeName\":\"$PG_LAYER\",\"srs\":\"EPSG:4326\"}}" \
        "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/postgis/featuretypes" \
        || echo "[Step 6] Warning: could not publish $PG_LAYER"
    else
      echo "[Step 6] PostGIS layer '$PG_LAYER' already published — skipping."
    fi
  done
else
  echo "[Step 6] POSTGIS_HOST not set — skipping PostGIS configuration."
fi

# ── Step 7: Publish Siricilla shapefile ───────────────────────────────────────
echo "[Step 7] Checking shapefile store '$STORE_NAME'..."

# Verify the .shp file is actually on disk before attempting publish
if [ ! -f "$SHAPEFILE_DIR/${LAYER_NAME}.shp" ]; then
  echo "ERROR: $SHAPEFILE_DIR/${LAYER_NAME}.shp not found — cannot publish layer."
  ls -lh "$SHAPEFILE_DIR/" 2>/dev/null || echo "Shapefile dir does not exist."
  exit 1
fi

SHP_STORE_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "$AUTH" \
  "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/$STORE_NAME.json")

if [ "$SHP_STORE_HTTP" != "200" ]; then
  echo "[Step 7] Creating shapefile store '$STORE_NAME'..."
  CREATE_SHP=$(curl -s -o /tmp/shp_store_resp.txt -w "%{http_code}" \
    -u "$AUTH" -X POST -H "Content-Type: application/json" \
    -d "{
      \"dataStore\": {
        \"name\": \"$STORE_NAME\",
        \"connectionParameters\": {
          \"entry\": [
            {\"@key\": \"url\",     \"$\": \"file:data/shapefiles/${LAYER_NAME}.shp\"},
            {\"@key\": \"charset\", \"$\": \"UTF-8\"}
          ]
        }
      }
    }" \
    "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores")

  if [ "$CREATE_SHP" = "201" ]; then
    echo "[Step 7] Store '$STORE_NAME' created."
  else
    echo "ERROR: Failed to create shapefile store (HTTP $CREATE_SHP):"
    cat /tmp/shp_store_resp.txt
    exit 1
  fi
else
  echo "[Step 7] Store '$STORE_NAME' already exists — skipping."
fi

SHP_LAYER_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "$AUTH" \
  "$GEOSERVER_URL/rest/layers/$GEOSERVER_WORKSPACE:$LAYER_NAME.json")

if [ "$SHP_LAYER_HTTP" != "200" ]; then
  echo "[Step 7] Publishing layer '$LAYER_NAME'..."
  PUBLISH=$(curl -s -o /tmp/shp_layer_resp.txt -w "%{http_code}" \
    -u "$AUTH" -X POST -H "Content-Type: application/json" \
    -d "{
      \"featureType\": {
        \"name\":       \"$LAYER_NAME\",
        \"nativeName\": \"$LAYER_NAME\",
        \"title\":      \"Siricilla\",
        \"srs\":        \"EPSG:4326\",
        \"enabled\":    true
      }
    }" \
    "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/$STORE_NAME/featuretypes")

  if [ "$PUBLISH" = "201" ]; then
    echo "[Step 7] Layer '$LAYER_NAME' published successfully."
    echo ""
    echo "WMS preview:"
    echo "  ${RENDER_EXTERNAL_URL}/geoserver/${GEOSERVER_WORKSPACE}/wms?service=WMS&version=1.1.0&request=GetMap&layers=${GEOSERVER_WORKSPACE}:${LAYER_NAME}&bbox=-180,-90,180,90&width=768&height=384&srs=EPSG:4326&styles=&format=image/png"
  else
    echo "ERROR: Failed to publish layer (HTTP $PUBLISH):"
    cat /tmp/shp_layer_resp.txt
    exit 1
  fi
else
  echo "[Step 7] Layer '$LAYER_NAME' already published — skipping."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "GeoServer initialisation complete."
echo "Workspace : $GEOSERVER_WORKSPACE"
echo "Layer     : $GEOSERVER_WORKSPACE:$LAYER_NAME"
echo "All config persisted on Render disk."
echo "========================================"

wait $GEOSERVER_PID
