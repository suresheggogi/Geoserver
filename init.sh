#!/bin/bash
set -e

GEOSERVER_DATA_DIR="/opt/geoserver/data_dir"
GEOSERVER_DEFAULT_DATA="/opt/geoserver_data_dir_default"  # backup of original data dir baked into image
GEOSERVER_URL="http://localhost:8080/geoserver"
AUTH="$GEOSERVER_ADMIN_USER:$GEOSERVER_ADMIN_PASSWORD"
SHAPEFILE_DIR="$GEOSERVER_DATA_DIR/data/shapefiles"

# ── Step 1: Seed data_dir on first boot ──────────────────────────────────────
# The Render disk is mounted at /opt/geoserver/data_dir.
# On first deploy it is completely empty — GeoServer will fail to start.
# We copy the default data dir (baked into the image) into the disk.
if [ ! -f "$GEOSERVER_DATA_DIR/global.xml" ]; then
  echo "Disk is empty — seeding GeoServer data directory from image defaults..."
  if [ -d "$GEOSERVER_DEFAULT_DATA" ]; then
    cp -r "$GEOSERVER_DEFAULT_DATA/." "$GEOSERVER_DATA_DIR/"
    echo "Data directory seeded from $GEOSERVER_DEFAULT_DATA"
  else
    echo "WARNING: Default data dir not found at $GEOSERVER_DEFAULT_DATA"
    echo "Checking alternate locations..."
    # Different GeoServer image versions use different paths
    for ALT in /opt/geoserver/data /usr/local/geoserver/data /var/geoserver/data; do
      if [ -f "$ALT/global.xml" ]; then
        echo "Found default data at $ALT — copying..."
        cp -r "$ALT/." "$GEOSERVER_DATA_DIR/"
        break
      fi
    done
  fi

  # Always ensure shapefiles directory exists on fresh disk
  mkdir -p "$SHAPEFILE_DIR"

  # Copy shapefiles from the image (they were baked in at build time
  # to /opt/geoserver_shapefiles as a staging area — see Dockerfile)
  if [ -d "/opt/geoserver_shapefiles" ]; then
    echo "Copying shapefiles to persistent disk..."
    cp -r /opt/geoserver_shapefiles/. "$SHAPEFILE_DIR/"
  fi
else
  echo "Persistent data directory already initialised — skipping seed."
  # Still sync any NEW shapefiles added in latest deploy
  if [ -d "/opt/geoserver_shapefiles" ]; then
    echo "Syncing shapefiles to persistent disk..."
    cp -rn /opt/geoserver_shapefiles/. "$SHAPEFILE_DIR/" 2>/dev/null || true
  fi
fi

# ── Step 2: Start GeoServer ───────────────────────────────────────────────────
echo "Starting GeoServer..."
/opt/startup.sh &

# ── Step 3: Wait for REST API to be ready ────────────────────────────────────
echo "Waiting for GeoServer REST API to be fully ready..."
for i in $(seq 1 90); do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" "$GEOSERVER_URL/rest/workspaces.json")
  if [ "$HTTP_CODE" = "200" ]; then
    echo "GeoServer REST API is ready! (attempt $i)"
    break
  fi
  echo "Attempt $i: REST API not ready (HTTP $HTTP_CODE), waiting 5s..."
  sleep 5
done

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" "$GEOSERVER_URL/rest/workspaces.json")
if [ "$HTTP_CODE" != "200" ]; then
  echo "ERROR: GeoServer REST API did not become ready (HTTP $HTTP_CODE). Exiting."
  exit 1
fi

# ── Step 4: Proxy base URL ────────────────────────────────────────────────────
if [ -n "$RENDER_EXTERNAL_URL" ]; then
  echo "Setting proxy base URL to $RENDER_EXTERNAL_URL/geoserver/"
  curl -s -u "$AUTH" -X PUT -H "Content-Type: application/xml" \
    -d "<global><proxyBaseUrl>${RENDER_EXTERNAL_URL}/geoserver/</proxyBaseUrl></global>" \
    "$GEOSERVER_URL/rest/settings" || echo "Warning: could not set proxy base URL"
fi

# ── Step 5: Create workspace (idempotent) ─────────────────────────────────────
echo "Checking workspace: $GEOSERVER_WORKSPACE"
WORKSPACE_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" \
  "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE.json")

if [ "$WORKSPACE_HTTP" = "200" ]; then
  echo "Workspace '$GEOSERVER_WORKSPACE' already exists on persistent disk — skipping."
else
  echo "Creating workspace: $GEOSERVER_WORKSPACE"
  CREATE_WS=$(curl -s -o /tmp/ws_response.txt -w "%{http_code}" -u "$AUTH" \
    -X POST -H "Content-Type: application/json" \
    -d "{\"workspace\":{\"name\":\"$GEOSERVER_WORKSPACE\"}}" \
    "$GEOSERVER_URL/rest/workspaces")
  if [ "$CREATE_WS" = "201" ]; then
    echo "Workspace '$GEOSERVER_WORKSPACE' created and saved to persistent disk."
  else
    echo "ERROR: Failed to create workspace (HTTP $CREATE_WS):"
    cat /tmp/ws_response.txt
    exit 1
  fi
fi

# ── Step 6: PostGIS datastore (idempotent) ────────────────────────────────────
if [ -n "$POSTGIS_HOST" ] && [ -n "$POSTGIS_DB" ]; then
  echo "Checking PostGIS datastore..."
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
      echo "PostGIS datastore created and saved to persistent disk."
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
    if [ "$LAYER_HTTP" = "200" ]; then
      echo "Layer '$LAYER' already published — skipping."
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

# ── Step 7: Publish shapefiles (idempotent) ───────────────────────────────────
if [ -d "$SHAPEFILE_DIR" ]; then
  echo "Publishing shapefiles from $SHAPEFILE_DIR ..."

  for SHP in "$SHAPEFILE_DIR"/*.shp; do
    [ -f "$SHP" ] || continue
    LAYER=$(basename "$SHP" .shp)
    STORE_NAME="shp_$LAYER"

    SHPSTORE_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" \
      "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/$STORE_NAME.json")

    if [ "$SHPSTORE_HTTP" = "200" ]; then
      echo "Shapefile store '$STORE_NAME' already exists — skipping."
    else
      echo "Creating shapefile store: $STORE_NAME"
      curl -s -o /tmp/shp_response.txt -u "$AUTH" \
        -X POST -H "Content-Type: application/json" \
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
        || echo "Warning: could not create shapefile store $STORE_NAME"
    fi

    LAYER_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" \
      "$GEOSERVER_URL/rest/layers/$GEOSERVER_WORKSPACE:$LAYER.json")

    if [ "$LAYER_HTTP" = "200" ]; then
      echo "Layer '$LAYER' already published — skipping."
    else
      echo "Publishing shapefile layer: $LAYER"
      curl -s -u "$AUTH" -X POST -H "Content-Type: application/json" \
        -d "{\"featureType\":{\"name\":\"$LAYER\",\"nativeName\":\"$LAYER\",\"srs\":\"EPSG:4326\"}}" \
        "$GEOSERVER_URL/rest/workspaces/$GEOSERVER_WORKSPACE/datastores/$STORE_NAME/featuretypes" \
        || echo "Warning: could not publish shapefile layer $LAYER"
    fi
  done
else
  echo "No shapefiles directory found — skipping."
fi

echo "========================================"
echo "GeoServer initialisation complete."
echo "All config is persisted on Render Disk."
echo "========================================"

wait
