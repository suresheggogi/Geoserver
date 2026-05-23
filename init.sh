#!/bin/bash
# init.sh — Auto-runs on GeoServer container startup
# Configures PostGIS datastore and publishes all vector layers

set -euo pipefail

GEOSERVER_URL="${GEOSERVER_URL:-http://localhost:8080/geoserver}"
ADMIN_USER="${GEOSERVER_ADMIN_USER:-admin}"
ADMIN_PASS="${GEOSERVER_ADMIN_PASSWORD:-geoserver}"

PG_HOST="${PG_HOST:-dpg-d82buslckfvc73f7m3j0-a}"
PG_PORT="${PG_PORT:-5432}"
PG_DATABASE="${PG_DATABASE:-geodb_0hyd}"
PG_USER="${PG_USER:-geodb_0hyd_user}"
PG_PASSWORD="${PG_PASSWORD:-changeme}"

WORKSPACE="geodb"
STORE_NAME="postgis_store"
AUTH="${ADMIN_USER}:${ADMIN_PASS}"

# Wait for GeoServer to be ready 
echo "⏳ Waiting for GeoServer..."
MAX_WAIT=120
WAITED=0
until curl -sf "${GEOSERVER_URL}/web/" > /dev/null 2>&1; do
  if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    echo "❌ GeoServer did not start within ${MAX_WAIT}s. Exiting."
    exit 1
  fi
  sleep 5
  WAITED=$((WAITED + 5))
  echo "   ...still waiting (${WAITED}s)"
done
echo "✅ GeoServer is up!"

# Helper: check if resource already exists
resource_exists() {
  local url="$1"
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" -u "${AUTH}" "${url}")
  [ "$status" = "200" ]
}

# 1. Create Workspace
if resource_exists "${GEOSERVER_URL}/rest/workspaces/${WORKSPACE}.json"; then
  echo "Workspace '${WORKSPACE}' already exists — skipping"
else
  echo "Creating workspace: ${WORKSPACE}"
  curl -sf -u "${AUTH}" \
    -X POST "${GEOSERVER_URL}/rest/workspaces" \
    -H "Content-Type: application/json" \
    -d "{\"workspace\": {\"name\": \"${WORKSPACE}\"}}"
  echo " Workspace created"
fi

# 2. Create PostGIS DataStore 
if resource_exists "${GEOSERVER_URL}/rest/workspaces/${WORKSPACE}/datastores/${STORE_NAME}.json"; then
  echo " DataStore '${STORE_NAME}' already exists — skipping"
else
  echo "🗄️  Creating PostGIS datastore: ${STORE_NAME}"
  curl -sf -u "${AUTH}" \
    -X POST "${GEOSERVER_URL}/rest/workspaces/${WORKSPACE}/datastores" \
    -H "Content-Type: application/json" \
    -d "{
      \"dataStore\": {
        \"name\": \"${STORE_NAME}\",
        \"type\": \"PostGIS\",
        \"enabled\": true,
        \"connectionParameters\": {
          \"entry\": [
            {\"@key\": \"host\",                 \"$\": \"${PG_HOST}\"},
            {\"@key\": \"port\",                 \"$\": \"${PG_PORT}\"},
            {\"@key\": \"database\",             \"$\": \"${PG_DATABASE}\"},
            {\"@key\": \"user\",                 \"$\": \"${PG_USER}\"},
            {\"@key\": \"passwd\",               \"$\": \"${PG_PASSWORD}\"},
            {\"@key\": \"dbtype\",               \"$\": \"postgis\"},
            {\"@key\": \"schema\",               \"$\": \"public\"},
            {\"@key\": \"Expose primary keys\",  \"$\": \"true\"},
            {\"@key\": \"validate connections\",  \"$\": \"true\"},
            {\"@key\": \"Connection timeout\",   \"$\": \"20\"},
            {\"@key\": \"min connections\",      \"$\": \"1\"},
            {\"@key\": \"max connections\",      \"$\": \"5\"},
            {\"@key\": \"fetch size\",           \"$\": \"1000\"},
            {\"@key\": \"preparedStatements\",   \"$\": \"true\"},
            {\"@key\": \"SSL mode\",             \"$\": \"disable\"}
          ]
        }
      }
    }"
  echo " DataStore created"
fi

# 3. Auto-publish all available PostGIS tables 
echo "Fetching available feature types..."
FEATURE_TYPES=$(curl -sf -u "${AUTH}" \
  "${GEOSERVER_URL}/rest/workspaces/${WORKSPACE}/datastores/${STORE_NAME}/featuretypes?list=available" \
  -H "Accept: application/json")

echo "  Found: ${FEATURE_TYPES}"

TABLES=$(echo "${FEATURE_TYPES}" | jq -r '.list.string[]?' 2>/dev/null || echo "")

if [ -z "$TABLES" ]; then
  echo "No new tables to publish (all may already be published)"
else
  echo "${TABLES}" | while read -r TABLE; do
    if resource_exists "${GEOSERVER_URL}/rest/workspaces/${WORKSPACE}/datastores/${STORE_NAME}/featuretypes/${TABLE}.json"; then
      echo "  ℹLayer '${TABLE}' already published — skipping"
    else
      echo " Publishing: ${TABLE}"
      HTTP_CODE=$(curl -s -o /tmp/gs_response.txt -w "%{http_code}" \
        -u "${AUTH}" \
        -X POST "${GEOSERVER_URL}/rest/workspaces/${WORKSPACE}/datastores/${STORE_NAME}/featuretypes" \
        -H "Content-Type: application/json" \
        -d "{
          \"featureType\": {
            \"name\": \"${TABLE}\",
            \"nativeName\": \"${TABLE}\",
            \"title\": \"${TABLE}\",
            \"srs\": \"EPSG:4326\",
            \"projectionPolicy\": \"REPROJECT_TO_DECLARED\",
            \"enabled\": true
          }
        }")
      if [ "$HTTP_CODE" = "201" ]; then
        echo "   Published: ${TABLE}"
        echo "     WMS: ${GEOSERVER_URL}/${WORKSPACE}/wms?service=WMS&version=1.1.0&request=GetMap&layers=${WORKSPACE}:${TABLE}&bbox=-180,-90,180,90&width=768&height=384&srs=EPSG:4326&format=image/png"
      else
        echo "      Failed (HTTP ${HTTP_CODE}): $(cat /tmp/gs_response.txt)"
      fi
    fi
  done
fi

echo ""
echo " init.sh complete!"
echo "   UI:  ${GEOSERVER_URL}/web/"
echo "   WMS: ${GEOSERVER_URL}/${WORKSPACE}/wms"
echo "   WFS: ${GEOSERVER_URL}/${WORKSPACE}/wfs"