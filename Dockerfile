FROM docker.osgeo.org/geoserver:2.28.3


USER root
RUN apt-get update && apt-get install -y curl jq && rm -rf /var/lib/apt/lists/*
# GeoServer data directory
ENV GEOSERVER_DATA_DIR=/opt/geoserver/data
ENV GEOSERVER_REQUIRE_FILE=/opt/geoserver/data/global.xml


#Admin credentials (override via Render env vars)
ENV GEOSERVER_ADMIN_USER=admin
ENV GEOSERVER_ADMIN_PASSWORD=geoserver


#DB connection env vars (set real values in Render dashboard)
ENV PG_HOST=dpg-d82buslckfvc73f7m3j0-a
ENV PG_PORT=5432
ENV PG_DATABASE=geodb_0hyd
ENV PG_USER=geodb_0hyd_user
ENV PG_PASSWORD=RLzoieV1g6cJYmi5ZUvLuVK9rxhLdCqm

#JVM tuning for Render Starter (512 MB RAM)
ENV JAVA_OPTS="-Xms256m -Xmx512m \
  -XX:+UseG1GC \
  -XX:MaxGCPauseMillis=200 \
  -Djava.awt.headless=true \
  -Dfile.encoding=UTF-8 \
  -Djavax.xml.transform.TransformerFactory=com.sun.org.apache.xalan.internal.xsltc.trax.TransformerFactoryImpl"



#Copy startup + setup scripts
COPY scripts/setup_geoserver.sh /docker-entrypoint-init.d/setup_geoserver.sh
RUN chmod +x /docker-entrypoint-init.d/setup_geoserver.sh

#Persistent data dir (Render disk mounts here)
VOLUME ["/opt/geoserver/data"]

EXPOSE 8080

#Healthcheck
HEALTHCHECK --interval=30s --timeout=15s --start-period=90s --retries=3 \
  CMD curl -sf http://localhost:8080/geoserver/web/ || exit 1

USER geoserver