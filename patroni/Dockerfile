FROM postgres:16-bookworm
USER root
RUN apt-get update && apt-get install -y python3 python3-pip python3-psycopg2 curl jq && rm -rf /var/lib/apt/lists/*
RUN pip3 install --break-system-packages patroni[etcd] psycopg2-binary
COPY patroni.yml /etc/patroni.yml
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && chown postgres:postgres /etc/patroni.yml
USER postgres
EXPOSE 5432 8008
ENTRYPOINT ["/entrypoint.sh"]