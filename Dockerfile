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
ENV PG_PASSWORD=RLzoieV1g6cJYmi5ZUvLuVK9rxhLdCqm

ENV PORT=8080
RUN sed -i 's/port="8080"/port="${PORT}"/g' /opt/config/server.xml

# Service is on free plan — aggressively trim memory.
# Both JAVA_OPTS and CATALINA_OPTS (= $EXTRA_JAVA_OPTS) are passed to JVM.
ENV EXTRA_JAVA_OPTS="-Xms96m -Xmx160m \
  -XX:+UseSerialGC \
  -XX:MaxGCPauseMillis=500 \
  -Xss256k \
  -XX:ReservedCodeCacheSize=64m"

ENV JAVA_OPTS="-Xms96m -Xmx160m \
  -XX:+UseSerialGC \
  -XX:MaxGCPauseMillis=500 \
  -Xss256k \
  -XX:ReservedCodeCacheSize=64m \
  -XX:MaxMetaspaceSize=48m \
  -XX:CompressedClassSpaceSize=16m \
  -Djava.awt.headless=true \
  -Dfile.encoding=UTF-8 \
  -DGEOSERVER_CSRF_DISABLED=true"

COPY init.sh /opt/init.sh
COPY shapefiles /opt/geoserver/shapefiles
COPY entrypoint.sh /opt/entrypoint.sh
RUN chmod +x /opt/init.sh /opt/entrypoint.sh

VOLUME ["/opt/geoserver/data"]
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=15s --start-period=120s --retries=3 \
  CMD curl -sf -o /dev/null "http://localhost:${PORT}/geoserver" || exit 1

ENTRYPOINT ["bash", "/opt/entrypoint.sh"]

# Base image runs as root — keep root for volume write access
USER root
