# ==============================================================================
# 🚀 Patroni for PostgreSQL 16 (基于 Debian Bookworm)
# ==============================================================================
# 💡 架构说明：
# 本镜像专为 PostgreSQL 高可用集群打造。
# 内部集成了 Patroni 守护进程与 Etcd3 通信组件。
# 所有敏感配置与集群拓扑均通过环境变量在运行时动态注入。
# ==============================================================================

FROM postgres:16-bookworm

# 💡 开源规范：建议加上你的专属标签，方便他人溯源
LABEL maintainer="hotyue <请替换为你的邮箱或主页>"
LABEL description="PostgreSQL 16 HA Cluster Node powered by Patroni and Etcd3"

USER root

# ==========================================
# 1. 安装系统底层依赖
# ==========================================
# 包含 Python3 环境、网络诊断工具 curl 以及 JSON 解析工具 jq (用于终端快捷查看集群状态)
# 💡 优化：加入 --no-install-recommends 减少不必要的包，缩减镜像体积
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       python3 \
       python3-pip \
       python3-psycopg2 \
       curl \
       jq \
    && rm -rf /var/lib/apt/lists/*

# ==========================================
# 2. 安装 Patroni 及其高可用引擎
# ==========================================
# 💡 核心修复：强制使用 patroni[etcd3] 和 etcd3 依赖，彻底抛弃过时的 python-etcd
# 💡 适配提示：Debian 12 默认限制系统级 pip 安装，此处使用 --break-system-packages 放行
RUN pip3 install --break-system-packages patroni[etcd3] etcd3 psycopg2-binary

# ==========================================
# 3. 注入模板配置与启动逻辑
# ==========================================
# 注意：拷入的 patroni.yml 是纯净模板，启动时 Patroni 会自动捕获容器内的环境变量并将其填充
COPY patroni.yml /etc/patroni.yml
COPY entrypoint.sh /entrypoint.sh

# ==========================================
# 4. 权限收紧与安全加固
# ==========================================
# 确保文件权限归属正确，防止越权访问
RUN chmod +x /entrypoint.sh \
    && chown postgres:postgres /etc/patroni.yml

# 💡 安全最佳实践：切换回 postgres 原生非特权用户运行所有服务
USER postgres

# ==========================================
# 5. 暴露网络端口
# ==========================================
# 5432: PostgreSQL 原生数据库协议端口
# 8008: Patroni REST API 端口 (用于心跳健康检查与 Leader 选举通信)
EXPOSE 5432 8008

ENTRYPOINT ["/entrypoint.sh"]
