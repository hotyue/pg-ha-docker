#!/bin/bash
# 遇到错误立即退出
set -e

# ==========================================
# 1. 定义漂亮的日志打印函数
# ==========================================
log_info() { echo -e "\033[32m[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1\033[0m"; }
log_warn() { echo -e "\033[33m[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1\033[0m"; }
log_error() { echo -e "\033[31m[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1\033[0m"; exit 1; }

# ==========================================
# 2. 环境检查与变量获取
# ==========================================
if [ "$EUID" -ne 0 ]; then
  log_error "请使用 root 用户或 sudo 执行此脚本！"
fi

# 支持通过参数传入，实现零交互：bash install.sh <当前节点ID:1|2|3> <IP1> <IP2> <IP3>
NODE_ID=${1:-""}
NODE1_IP=${2:-""}
NODE2_IP=${3:-""}
NODE3_IP=${4:-""}

# 如果没有传参，则进行简单的终端交互
if [ -z "$NODE_ID" ] || [ -z "$NODE1_IP" ] || [ -z "$NODE2_IP" ] || [ -z "$NODE3_IP" ]; then
    log_warn "未检测到完整的启动参数，进入交互配置模式..."
    read -p "请输入当前节点的编号 (1, 2 或 3): " NODE_ID
    read -p "请输入 Node1 的 IP 地址: " NODE1_IP
    read -p "请输入 Node2 的 IP 地址: " NODE2_IP
    read -p "请输入 Node3 的 IP 地址: " NODE3_IP
fi

# 根据当前节点ID，确定当前节点的IP
if [ "$NODE_ID" == "1" ]; then CURRENT_IP=$NODE1_IP; 
elif [ "$NODE_ID" == "2" ]; then CURRENT_IP=$NODE2_IP; 
elif [ "$NODE_ID" == "3" ]; then CURRENT_IP=$NODE3_IP; 
else log_error "节点编号必须是 1, 2 或 3！"; fi

log_info "配置确认: 当前节点为 Node${NODE_ID} (${CURRENT_IP})"
log_info "集群 IP: Node1=${NODE1_IP}, Node2=${NODE2_IP}, Node3=${NODE3_IP}"

# ==========================================
# 3. 创建统一的运行目录
# ==========================================
BASE_DIR="/opt/docker/pg-ha"
log_info "正在清理并创建项目目录: ${BASE_DIR}"

mkdir -p ${BASE_DIR}/{patroni,haproxy,etcd-data,pg-data}
# 赋予所需权限，防止 docker 容器内无权限写入
chmod 777 ${BASE_DIR}/etcd-data
chmod 777 ${BASE_DIR}/pg-data

# ==========================================
# 4. 自动生成 docker-compose.yml
# ==========================================
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
log_info "正在生成核心编排文件: ${COMPOSE_FILE}"

cat << EOF > ${COMPOSE_FILE}
version: '3.8'

services:
  # [1] Etcd: 跨地域高延迟优化版本
  etcd:
    image: bitnami/etcd:3.5
    container_name: etcd
    restart: always
    network_mode: "host"
    environment:
      - ALLOW_NONE_AUTHENTICATION=yes
      - ETCD_NAME=etcd${NODE_ID}
      - ETCD_LISTEN_PEER_URLS=http://0.0.0.0:2380
      - ETCD_INITIAL_ADVERTISE_PEER_URLS=http://${CURRENT_IP}:2380
      - ETCD_LISTEN_CLIENT_URLS=http://0.0.0.0:2379
      - ETCD_ADVERTISE_CLIENT_URLS=http://${CURRENT_IP}:2379
      - ETCD_INITIAL_CLUSTER_TOKEN=pg-ha-cluster
      - ETCD_INITIAL_CLUSTER=etcd1=http://${NODE1_IP}:2380,etcd2=http://${NODE2_IP}:2380,etcd3=http://${NODE3_IP}:2380
      - ETCD_INITIAL_CLUSTER_STATE=new
      # 针对 200ms 高延迟的优化参数
      - ETCD_HEARTBEAT_INTERVAL=1000
      - ETCD_ELECTION_TIMEOUT=5000
    volumes:
      - ./etcd-data:/bitnami/etcd/data

  # [2] Patroni + PostgreSQL 核心数据库
  patroni:
    build: 
      context: ./patroni
    container_name: patroni
    restart: always
    network_mode: "host"
    privileged: true
    environment:
      - PATRONI_NAME=node${NODE_ID}
      - PATRONI_RESTAPI_LISTEN=0.0.0.0:8008
      - PATRONI_RESTAPI_CONNECT_ADDRESS=${CURRENT_IP}:8008
      - PATRONI_POSTGRESQL_LISTEN=0.0.0.0:5432
      - PATRONI_POSTGRESQL_CONNECT_ADDRESS=${CURRENT_IP}:5432
      - ETCD_HOSTS=${NODE1_IP}:2379,${NODE2_IP}:2379,${NODE3_IP}:2379
    volumes:
      - ./pg-data:/var/lib/postgresql/data
    depends_on:
      - etcd

  # [3] HAProxy 流量网关
  haproxy:
    image: haproxy:2.8-alpine
    container_name: haproxy
    restart: always
    network_mode: "host"
    volumes:
      - ./haproxy/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    depends_on:
      - patroni
EOF

# ==========================================
# 5. 生成 Patroni 相关的构建文件
# ==========================================
log_info "正在生成 Patroni 的 Dockerfile 和 entrypoint.sh..."

cat << 'EOF' > ${BASE_DIR}/patroni/Dockerfile
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
EOF

cat << 'EOF' > ${BASE_DIR}/patroni/entrypoint.sh
#!/bin/bash
set -e
export PATRONI_POSTGRESQL_DATA_DIR=${PATRONI_POSTGRESQL_DATA_DIR:-/var/lib/postgresql/data/patroni}
mkdir -p "$PATRONI_POSTGRESQL_DATA_DIR"
chmod 700 "$PATRONI_POSTGRESQL_DATA_DIR"
exec patroni /etc/patroni.yml
EOF

# ==========================================
# 6. 生成 Patroni 核心配置文件 (针对 200ms 延迟深度优化)
# ==========================================
log_info "正在生成 patroni.yml 配置文件..."

cat << EOF > ${BASE_DIR}/patroni/patroni.yml
scope: pg-ha-cluster
namespace: /db/
name: node${NODE_ID}

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${CURRENT_IP}:8008

etcd:
  hosts: ${NODE1_IP}:2379,${NODE2_IP}:2379,${NODE3_IP}:2379

bootstrap:
  dcs:
    ttl: 60
    loop_wait: 10
    retry_timeout: 20
    maximum_lag_on_failover: 33554432
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_connections: 100
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 1024MB
  initdb:
    - encoding: UTF8
    - data-checksums

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${CURRENT_IP}:5432
  data_dir: /var/lib/postgresql/data/patroni
  bin_dir: /usr/lib/postgresql/16/bin
  pgpass: /tmp/pgpass
  authentication:
    replication:
      username: replicator
      password: replpassword
    superuser:
      username: postgres
      password: pgpassword
  pg_hba:
    - host replication replicator 0.0.0.0/0 md5
    - host all all 0.0.0.0/0 md5
EOF

# ==========================================
# 7. 生成 HAProxy 配置文件
# ==========================================
log_info "正在生成 HAProxy 路由与负载均衡配置..."

cat << EOF > ${BASE_DIR}/haproxy/haproxy.cfg
global
    maxconn 1000

defaults
    mode tcp
    timeout client 30m
    timeout server 30m
    timeout connect 5s

frontend pg_write_front
    bind *:5000
    default_backend pg_write_back

backend pg_write_back
    option httpchk GET /master
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server node1 ${NODE1_IP}:5432 maxconn 100 check port 8008
    server node2 ${NODE2_IP}:5432 maxconn 100 check port 8008
    server node3 ${NODE3_IP}:5432 maxconn 100 check port 8008

frontend pg_read_front
    bind *:5001
    default_backend pg_read_back

backend pg_read_back
    balance roundrobin
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server node1 ${NODE1_IP}:5432 maxconn 100 check port 8008
    server node2 ${NODE2_IP}:5432 maxconn 100 check port 8008
    server node3 ${NODE3_IP}:5432 maxconn 100 check port 8008

listen stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 5s
EOF

# ==========================================
# 8. 执行部署
# ==========================================
log_info "配置全部生成完毕，开始构建并启动集群..."
cd ${BASE_DIR}

if command -v docker-compose &> /dev/null; then
    docker-compose build
    docker-compose up -d
elif docker compose version &> /dev/null; then
    docker compose build
    docker compose up -d
else
    log_error "未找到 docker-compose 或 docker compose 命令，请先安装 Docker 环境！"
fi

log_info "部署任务已下发！容器正在后台启动。"
log_info "您可以使用以下命令查看集群状态："
log_info "  docker exec -it patroni patronioctl -c /etc/patroni.yml topology"
log_info "部署完成！主库写入口: 5000，只读入口: 5001，HAProxy 面板: 8404。"