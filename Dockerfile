FROM docker.osgeo.org/geoserver:2.28.3

USER root
RUN apt-get update && apt-get install -y curl jq gdal-bin postgresql-client && rm -rf /var/lib/apt/lists/*

ENV GEOSERVER_DATA_DIR=/opt/geoserver/data
ENV GEOSERVER_REQUIRE_FILE=/opt/geoserver/data/global.xml
ENV GEOSERVER_ADMIN_USER=admin
ENV GEOSERVER_ADMIN_PASSWORD=geoserver

# DB defaults — override in Render dashboard
ENV PG_HOST=localhost
ENV PG_PORT=5432
ENV PG_DATABASE=geodb
ENV PG_USER=geodb_user
ENV PG_PASSWORD=changeme

ENV JAVA_OPTS="-Xms128m -Xmx400m \
  -XX:+UseG1GC \
  -XX:MaxGCPauseMillis=200 \
  -XX:MaxMetaspaceSize=128m \
  -Djava.awt.headless=true \
  -Dfile.encoding=UTF-8 \
  -DGEOSERVER_CSRF_DISABLED=true"

COPY init.sh /docker-entrypoint-init.d/init.sh
COPY shapefiles /opt/geoserver/shapefiles
RUN chmod +x /docker-entrypoint-init.d/init.sh

VOLUME ["/opt/geoserver/data"]
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=15s --start-period=90s --retries=3 \
  CMD curl -sf http://localhost:8080/geoserver/web/ || exit 1

USER geoserver