FROM docker.osgeo.org/geoserver:2.28.3

USER root

RUN apt-get update && apt-get install -y curl jq unzip && rm -rf /var/lib/apt/lists/*

ENV GEOSERVER_ADMIN_USER=admin
ENV GEOSERVER_ADMIN_PASSWORD=testing123
ENV POSTGIS_HOST=
ENV POSTGIS_PORT=5432
ENV POSTGIS_DB=
ENV POSTGIS_USER=
ENV POSTGIS_PASSWORD=
ENV POSTGIS_SCHEMA=public
ENV GEOSERVER_WORKSPACE=myworkspace

# Find where GeoServer data_dir actually lives and back it up
# The 2.28.x image uses /opt/geoserver_data as the data directory
RUN set -e; \
    for DIR in /opt/geoserver_data /opt/geoserver/data /var/geoserver/data /usr/local/geoserver/data /opt/geoserver/webapps/geoserver/data /usr/local/tomcat/webapps/geoserver/data; do \
      if [ -f "$DIR/global.xml" ]; then \
        echo "Found GeoServer data dir at: $DIR"; \
        cp -r "$DIR" /opt/geoserver_data_dir_default; \
        echo "$DIR" > /opt/geoserver_data_dir_path.txt; \
        break; \
      fi; \
    done; \
    if [ ! -f /opt/geoserver_data_dir_path.txt ]; then \
      echo "ERROR: Could not find GeoServer data dir"; \
      find / -name "global.xml" 2>/dev/null | head -5; \
      exit 1; \
    fi

# Stage shapefiles separately
COPY shapefiles/ /opt/geoserver_shapefiles/

COPY init.sh /init.sh
RUN chmod +x /init.sh

ENTRYPOINT ["/init.sh"]
