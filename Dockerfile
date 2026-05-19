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

# 1. Backup the default data_dir INTO the image
RUN cp -r /opt/geoserver/data_dir /opt/geoserver_data_dir_default

# 2. Stage shapefiles separately (disk will overwrite /data_dir on mount)
COPY shapefiles/ /opt/geoserver_shapefiles/

COPY init.sh /init.sh
RUN chmod +x /init.sh

ENTRYPOINT ["/init.sh"]
