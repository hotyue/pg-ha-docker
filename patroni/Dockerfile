FROM postgres:16-bookworm

USER root

# 安装必要的系统依赖
RUN apt-get update && apt-get install -y python3 python3-pip python3-psycopg2 curl jq && rm -rf /var/lib/apt/lists/*

# 💡 核心修复：强制使用 etcd3 扩展和依赖，彻底抛弃旧版 python-etcd
RUN pip3 install --break-system-packages patroni[etcd3] etcd3 psycopg2-binary

COPY patroni.yml /etc/patroni.yml
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh && chown postgres:postgres /etc/patroni.yml

USER postgres
EXPOSE 5432 8008

ENTRYPOINT ["/entrypoint.sh"]