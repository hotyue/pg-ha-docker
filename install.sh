#!/bin/bash
# ==============================================================================
# 🚀 PostgreSQL 高可用集群 (Patroni + Etcd + HAProxy) 自动化部署脚本
# ==============================================================================
# 架构特性：环境变量驱动 (Environment-Driven) + 双栈网络兼容 (IPv4/IPv6)
# 核心升级：跨国网络自适应调优 (Auto-Tuning) + 集群配置防脑裂强一致性对齐
# 修复记录：解决 HAProxy 配置文件中 ${HA_INTER_TIME} 导致的 $ 字符解析错误
# ==============================================================================

# 遇到错误立即退出
set -e

# ==========================================
# 1. 核心仓库配置 (⚠️ 已对齐至 Forgejo 实例)
# ==========================================
FORGEJO_DOMAIN="git.94211762.xyz"
USER_NAME="hotyue"
REPO_NAME="pg-ha-docker"
BRANCH_NAME="main"
# 注意：Forgejo 的 Raw 路径必须包含 /raw/branch/
RAW_BASE_URL="https://${FORGEJO_DOMAIN}/${USER_NAME}/${REPO_NAME}/raw/branch/${BRANCH_NAME}"

# ==========================================
# 2. 定义漂亮的日志与工具函数
# ==========================================
log_info() { echo -e "\033[32m[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1\033[0m"; }
log_warn() { echo -e "\033[33m[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1\033[0m"; }
log_error() { echo -e "\033[31m[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1\033[0m"; exit 1; }

# IPv6 智能格式化函数
format_ip() {
    local ip="$1"
    if [[ "$ip" == *":"* ]] && [[ "$ip" != *"["* ]]; then
        echo "[$ip]"
    else
        echo "$ip"
    fi
}

# 延迟探测函数 (提取平均毫秒数)
get_latency() {
    local target_ip=$(echo "$1" | tr -d '[]') # 剥离方括号以确保 ping 命令正常工作
    # 取 ping 结果的倒数第一行，用 / 分割取第5段(avg)，然后用 . 分割取整数部分
    local lat=$(ping -c 3 -W 2 "$target_ip" 2>/dev/null | tail -n 1 | awk -F '/' '{print $5}' | awk -F '.' '{print $1}')
    # 如果没取到数字（比如 ping 失败或禁 ping），默认给极其悲观的 500ms
    if ! [[ "$lat" =~ ^[0-9]+$ ]]; then lat=500; fi
    echo "$lat"
}

# ==========================================
# 3. 环境检查与拓扑获取
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

CURRENT_URL_IP=$(format_ip "$CURRENT_IP")
NODE1_URL_IP=$(format_ip "$NODE1_IP")
NODE2_URL_IP=$(format_ip "$NODE2_IP")
NODE3_URL_IP=$(format_ip "$NODE3_IP")

log_info "✅ 配置确认: 当前节点 Node${NODE_ID} (${CURRENT_URL_IP})"

# ==========================================
# 4. 安全凭证与集群共识网络参数注入
# ==========================================
log_info "正在配置集群安全凭证与网络参数..."

read -p "请输入数据库超级管理员(postgres)密码 [直接回车自动生成]: " input_root_pw </dev/tty
if [ -z "$input_root_pw" ]; then
    PG_ROOT_PASSWORD=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
    log_warn "已自动生成 postgres 密码，部署其它节点时请使用此密码！"
else
    PG_ROOT_PASSWORD=$input_root_pw
fi

read -p "请输入数据库底层同步(replicator)密码 [直接回车自动生成]: " input_repl_pw </dev/tty
if [ -z "$input_repl_pw" ]; then
    PG_REPL_PASSWORD=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
    log_warn "已自动生成 replicator 密码，部署其它节点时请使用此密码！"
else
    PG_REPL_PASSWORD=$input_repl_pw
fi

# 💡 核心升级：集群网络预检与自适应调优 (防脑裂一致性控制)
if [ "$NODE_ID" == "1" ]; then
    log_info "正在对 Node 2 和 Node 3 进行物理网络延迟探测..."
    LAT_2=$(get_latency "$NODE2_IP")
    LAT_3=$(get_latency "$NODE3_IP")
    
    # 获取最大短板延迟
    MAX_LAT=$(( LAT_2 > LAT_3 ? LAT_2 : LAT_3 ))
    log_info "探测到集群最大网络延迟: ${MAX_LAT}ms"

    # 架构决策引擎
    if [ "$MAX_LAT" -lt 50 ]; then
        log_info "⚡ 判定为 [同城/内网极速环境]"
        ETCD_ELECTION_TIMEOUT=5000; PATRONI_TTL=30; PATRONI_LOOP_WAIT=10; PATRONI_RETRY_TIMEOUT=10; HA_INTER_TIME=2000
    elif [ "$MAX_LAT" -lt 150 ]; then
        log_info "🌍 判定为 [跨省/中等延迟环境]"
        ETCD_ELECTION_TIMEOUT=10000; PATRONI_TTL=60; PATRONI_LOOP_WAIT=10; PATRONI_RETRY_TIMEOUT=30; HA_INTER_TIME=4000
    else
        log_info "🌌 判定为 [跨国/极高延迟环境]"
        ETCD_ELECTION_TIMEOUT=20000; PATRONI_TTL=90; PATRONI_LOOP_WAIT=20; PATRONI_RETRY_TIMEOUT=60; HA_INTER_TIME=5000
    fi
else
    echo -e "\n\033[33m⚠️ 检测到您正在部署备用节点 (Node ${NODE_ID})\033[0m"
    echo -e "\033[36m为了防止集群因超时判定不一致而发生脑裂，请查阅 Node 1 部署成功时的面板截图，\033[0m"
    echo -e "\033[36m并在此准确填入当时的【网络共识参数】(若为空将导致部署失败)：\033[0m"
    read -p "请输入 ETCD_ELECTION_TIMEOUT: " ETCD_ELECTION_TIMEOUT </dev/tty
    read -p "请输入 PATRONI_TTL: " PATRONI_TTL </dev/tty
    read -p "请输入 PATRONI_LOOP_WAIT: " PATRONI_LOOP_WAIT </dev/tty
    read -p "请输入 PATRONI_RETRY_TIMEOUT: " PATRONI_RETRY_TIMEOUT </dev/tty
    read -p "请输入 HA_INTER_TIME: " HA_INTER_TIME </dev/tty
    
    if [ -z "$ETCD_ELECTION_TIMEOUT" ] || [ -z "$HA_INTER_TIME" ]; then
        log_error "集群共识参数不能为空！请重新运行脚本并输入从 Node 1 复制的正确参数！"
    fi
fi

# ==========================================
# 5. 创建统一的运行目录与 .env 文件
# ==========================================
BASE_DIR="/opt/docker/pg-ha"
log_info "正在初始化运行目录并生成环境变量 (.env): ${BASE_DIR}"

mkdir -p ${BASE_DIR}/{patroni,haproxy,etcd-data,pg-data}
chmod 777 ${BASE_DIR}/etcd-data
chmod 777 ${BASE_DIR}/pg-data

# 💡 架构重构核心：生成单一真理源 .env 文件 (包含自适应参数)
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

# 分布式集群防脑裂网络共识参数
ETCD_ELECTION_TIMEOUT=${ETCD_ELECTION_TIMEOUT}
PATRONI_TTL=${PATRONI_TTL}
PATRONI_LOOP_WAIT=${PATRONI_LOOP_WAIT}
PATRONI_RETRY_TIMEOUT=${PATRONI_RETRY_TIMEOUT}
HA_INTER_TIME=${HA_INTER_TIME}
EOF

chmod 600 ${BASE_DIR}/.env # 保护包含密码的文件

# ==========================================
# 6. 从 Forgejo 实例动态拉取模板文件
# ==========================================
download_file() {
    local remote_file_path=$1
    local local_file_path="${BASE_DIR}/${remote_file_path}"
    local download_url="${RAW_BASE_URL}/${remote_file_path}"

    log_info "正在拉取: ${remote_file_path} ..."
    if ! curl -fsSL "$download_url" -o "$local_file_path"; then
        log_error "拉取失败: ${download_url}，请检查网络或 Forgejo 仓库地址！"
    fi
}

download_file "docker-compose.yml"
download_file "patroni/Dockerfile"
download_file "patroni/entrypoint.sh"
download_file "patroni/patroni.yml"
download_file "haproxy/haproxy.cfg"

# 💡 关键修正：动态渲染 HAProxy 配置文件
# 从根源解决 HAProxy 无法解析配置文件中 $ 变量占位符的问题
log_info "正在执行配置预渲染 (Rendering HAProxy Config)..."
sed -i "s/\${HA_INTER_TIME}/${HA_INTER_TIME}/g" ${BASE_DIR}/haproxy/haproxy.cfg

echo "" >> ${BASE_DIR}/haproxy/haproxy.cfg
chmod +x ${BASE_DIR}/patroni/entrypoint.sh

# ==========================================
# 7. 执行部署
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

# ==========================================
# 8. 完美闭环的部署总结面板
# ==========================================
log_info "🎉 部署任务圆满完成！双栈兼容容器已在后台安全运行。"

if [ "$NODE_ID" == "1" ]; then
    echo -e "\n=============================================================================="
    echo -e "⚠️  \033[1;31m【极其重要】集群共识网络参数与凭证 (防脑裂生命线)\033[0m ⚠️"
    echo -e "=============================================================================="
    echo -e "请务必复制或截图保存以下全部内容！"
    echo -e "在部署 Node 2 和 Node 3 时，脚本将要求您严格填入这些参数，"
    echo -e "以确保整个分布式集群的时钟与判定线绝对一致！"
    echo -e "------------------------------------------------------------------------------"
    echo -e "\033[33mPG_ROOT_PASSWORD\033[0m      : \033[1;32m${PG_ROOT_PASSWORD}\033[0m"
    echo -e "\033[33mPG_REPL_PASSWORD\033[0m      : \033[1;32m${PG_REPL_PASSWORD}\033[0m"
    echo -e "\033[33mETCD_ELECTION_TIMEOUT\033[0m : \033[1;32m${ETCD_ELECTION_TIMEOUT}\033[0m"
    echo -e "\033[33mPATRONI_TTL\033[0m           : \033[1;32m${PATRONI_TTL}\033[0m"
    echo -e "\033[33mPATRONI_LOOP_WAIT\033[0m     : \033[1;32m${PATRONI_LOOP_WAIT}\033[0m"
    echo -e "\033[33mPATRONI_RETRY_TIMEOUT\033[0m : \033[1;32m${PATRONI_RETRY_TIMEOUT}\033[0m"
    echo -e "\033[33mHA_INTER_TIME\033[0m         : \033[1;32m${HA_INTER_TIME}\033[0m"
    echo -e "==============================================================================\n"
fi

echo -e "=============================================="
echo -e "                 集群访问指南                   "
echo -e "=============================================="
echo -e "写库地址 (Primary) : ${CURRENT_URL_IP}:5000"
echo -e "读库地址 (Replica) : ${CURRENT_URL_IP}:5001"
echo -e "监控面板 (HAProxy) : http://${CURRENT_URL_IP}:8404/stats"
echo -e "==============================================\n"