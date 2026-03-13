#!/bin/bash
# ==============================================================================
# 🚀 PostgreSQL 高可用集群 (Patroni + Etcd + HAProxy) 自动化部署脚本
# ==============================================================================
# 架构特性：环境变量驱动 (Environment-Driven) + 双栈网络兼容 (IPv4/IPv6)
# ==============================================================================

# 遇到错误立即退出
set -e

# ==========================================
# 1. 核心仓库配置 (⚠️ 请修改为你的真实信息)
# ==========================================
GITHUB_USER="hotyue"
GITHUB_REPO="pg-ha-docker"
GITHUB_BRANCH="main"
RAW_BASE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"

# ==========================================
# 2. 定义漂亮的日志打印函数
# ==========================================
log_info() { echo -e "\033[32m[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1\033[0m"; }
log_warn() { echo -e "\033[33m[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1\033[0m"; }
log_error() { echo -e "\033[31m[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1\033[0m"; exit 1; }

# ==========================================
# 3. 环境检查与变量获取
# ==========================================
if [ "$EUID" -ne 0 ]; then
  log_error "请使用 root 用户或 sudo 执行此脚本！"
fi

# 支持通过 curl 一键传参 (ID IP1 IP2 IP3)
NODE_ID=${1:-""}
NODE1_IP=${2:-""}
NODE2_IP=${3:-""}
NODE3_IP=${4:-""}

# 交互式获取节点 IP 拓扑
if [ -z "$NODE_ID" ] || [ -z "$NODE1_IP" ] || [ -z "$NODE2_IP" ] || [ -z "$NODE3_IP" ]; then
    log_warn "未检测到完整的启动参数，进入交互配置模式..."
    read -p "请输入当前节点的编号 (1, 2 或 3): " NODE_ID </dev/tty
    read -p "请输入 Node1 的 IP 地址: " NODE1_IP </dev/tty
    read -p "请输入 Node2 的 IP 地址: " NODE2_IP </dev/tty
    read -p "请输入 Node3 的 IP 地址: " NODE3_IP </dev/tty
fi

if [ "$NODE_ID" == "1" ]; then CURRENT_IP=$NODE1_IP; 
elif [ "$NODE_ID" == "2" ]; then CURRENT_IP=$NODE2_IP; 
elif [ "$NODE_ID" == "3" ]; then CURRENT_IP=$NODE3_IP; 
else log_error "节点编号错误：必须是 1, 2 或 3！"; fi

# 💡 核心升级：密码同步逻辑 (保障集群握手成功)
log_info "正在配置集群安全凭证..."
read -p "请输入数据库超级管理员(postgres)密码 [直接回车自动生成]: " input_root_pw </dev/tty
if [ -z "$input_root_pw" ]; then
    PG_ROOT_PASSWORD=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
    log_warn "已自动生成 postgres 密码，请务必在部署其他节点时使用相同的密码！"
else
    PG_ROOT_PASSWORD=$input_root_pw
fi

read -p "请输入数据库底层同步(replicator)密码 [直接回车自动生成]: " input_repl_pw </dev/tty
if [ -z "$input_repl_pw" ]; then
    PG_REPL_PASSWORD=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
    log_warn "已自动生成 replicator 密码，请务必在部署其他节点时使用相同的密码！"
else
    PG_REPL_PASSWORD=$input_repl_pw
fi

# IPv6 智能格式化函数
format_ip() {
    local ip="$1"
    if [[ "$ip" == *":"* ]] && [[ "$ip" != *"["* ]]; then
        echo "[$ip]"
    else
        echo "$ip"
    fi
}

CURRENT_URL_IP=$(format_ip "$CURRENT_IP")
NODE1_URL_IP=$(format_ip "$NODE1_IP")
NODE2_URL_IP=$(format_ip "$NODE2_IP")
NODE3_URL_IP=$(format_ip "$NODE3_IP")

log_info "✅ 配置确认: 当前节点 Node${NODE_ID} (${CURRENT_URL_IP})"

# ==========================================
# 4. 创建统一的运行目录与 .env 文件
# ==========================================
BASE_DIR="/opt/docker/pg-ha"
log_info "正在初始化运行目录并生成环境变量 (.env): ${BASE_DIR}"

mkdir -p ${BASE_DIR}/{patroni,haproxy,etcd-data,pg-data}
chmod 777 ${BASE_DIR}/etcd-data
chmod 777 ${BASE_DIR}/pg-data

# 💡 架构重构核心：生成单一真理源 .env 文件
cat <<EOF > ${BASE_DIR}/.env
# ==========================================
# 自动生成的集群环境变量配置
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# ==========================================
NODE_ID=${NODE_ID}
CURRENT_IP=${CURRENT_URL_IP}
NODE1_IP=${NODE1_URL_IP}
NODE2_IP=${NODE2_URL_IP}
NODE3_IP=${NODE3_URL_IP}

# 数据库密码凭证
PG_ROOT_PASSWORD=${PG_ROOT_PASSWORD}
PG_REPL_PASSWORD=${PG_REPL_PASSWORD}
EOF

chmod 600 ${BASE_DIR}/.env # 保护包含密码的文件

# ==========================================
# 5. 从 GitHub 动态拉取原汁原味的模板文件
# ==========================================
download_file() {
    local remote_file_path=$1
    local local_file_path="${BASE_DIR}/${remote_file_path}"
    local download_url="${RAW_BASE_URL}/${remote_file_path}"

    log_info "正在拉取: ${remote_file_path} ..."
    if ! curl -fsSL "$download_url" -o "$local_file_path"; then
        log_error "拉取失败: ${download_url}，请检查网络或 GitHub 仓库地址！"
    fi
}

# 💡 核心升级：不再需要 sed 替换！文件拉下来直接用，变量全靠 .env 注入
download_file "docker-compose.yml"
download_file "patroni/Dockerfile"
download_file "patroni/entrypoint.sh"
download_file "patroni/patroni.yml"
download_file "haproxy/haproxy.cfg"

# 保留 HAProxy 换行符强迫症修复
echo "" >> ${BASE_DIR}/haproxy/haproxy.cfg
chmod +x ${BASE_DIR}/patroni/entrypoint.sh

# ==========================================
# 6. 执行部署
# ==========================================
log_info "所有配置均已就绪，开始编译镜像并启动双栈高可用集群..."
cd ${BASE_DIR}

if command -v docker-compose &> /dev/null; then
    docker-compose build
    docker-compose up -d
elif docker compose version &> /dev/null; then
    docker compose build
    docker compose up -d
else
    log_error "未找到 Docker Compose 环境，请先安装 Docker！"
fi

log_info "🎉 部署任务圆满完成！双栈兼容容器已在后台安全运行。"
echo -e "\n=============================================="
echo -e "                 集群访问指南                   "
echo -e "=============================================="
echo -e "超级管理员 (postgres) 密码: \033[33m${PG_ROOT_PASSWORD}\033[0m"
echo -e "底层同步 (replicator) 密码: \033[33m${PG_REPL_PASSWORD}\033[0m"
echo -e "⚠️ 请务必在部署另外两个节点时，手动输入上述密码！\n"
echo -e "写库地址 (Primary) : ${CURRENT_URL_IP}:5000"
echo -e "读库地址 (Replica) : ${CURRENT_URL_IP}:5001"
echo -e "监控面板 (HAProxy) : http://${CURRENT_URL_IP}:8404/stats"
echo -e "==============================================\n"