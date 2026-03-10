#!/bin/bash
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

# 支持通过 curl 一键传参
NODE_ID=${1:-""}
NODE1_IP=${2:-""}
NODE2_IP=${3:-""}
NODE3_IP=${4:-""}

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

# 💡 核心升级：IPv6 智能格式化函数
# 如果输入的是 IPv6 地址（包含冒号），自动为其套上方括号 [ ]，以兼容所有带端口的 URL 解析
format_ip() {
    local ip="$1"
    if [[ "$ip" == *":"* ]] && [[ "$ip" != *"["* ]]; then
        echo "[$ip]"
    else
        echo "$ip"
    fi
}

# 转换所有的 IP 变量为 URL 安全格式（支持双栈）
CURRENT_URL_IP=$(format_ip "$CURRENT_IP")
NODE1_URL_IP=$(format_ip "$NODE1_IP")
NODE2_URL_IP=$(format_ip "$NODE2_IP")
NODE3_URL_IP=$(format_ip "$NODE3_IP")

log_info "✅ 配置确认: 当前节点为 Node${NODE_ID} (${CURRENT_URL_IP})"
log_info "✅ 集群拓扑: Node1=${NODE1_URL_IP}, Node2=${NODE2_URL_IP}, Node3=${NODE3_URL_IP}"

# ==========================================
# 4. 创建统一的运行目录
# ==========================================
BASE_DIR="/opt/docker/pg-ha"
log_info "正在初始化并授权项目运行目录: ${BASE_DIR}"

mkdir -p ${BASE_DIR}/{patroni,haproxy,etcd-data,pg-data}
chmod 777 ${BASE_DIR}/etcd-data
chmod 777 ${BASE_DIR}/pg-data

# ==========================================
# 5. 从 GitHub 动态拉取模板文件并注入变量
# ==========================================
# 定义一个下载并替换变量的通用函数
download_and_render() {
    local remote_file_path=$1
    local local_file_path="${BASE_DIR}/${remote_file_path}"
    local download_url="${RAW_BASE_URL}/${remote_file_path}"

    log_info "正在拉取: ${remote_file_path} ..."
    
    # 尝试下载文件，如果 HTTP 状态码不是 200 则报错退出
    if ! curl -fsSL "$download_url" -o "$local_file_path"; then
        log_error "拉取文件失败: ${download_url}，请检查网络或 GitHub 仓库地址！"
    fi

    # 💡 核心升级：使用 | 作为 sed 的分隔符，完美避开 IPv6 地址中冒号的解析冲突
    sed -i "s|<NODE_ID>|${NODE_ID}|g" "$local_file_path"
    sed -i "s|<CURRENT_IP>|${CURRENT_URL_IP}|g" "$local_file_path"
    sed -i "s|<NODE1_IP>|${NODE1_URL_IP}|g" "$local_file_path"
    sed -i "s|<NODE2_IP>|${NODE2_URL_IP}|g" "$local_file_path"
    sed -i "s|<NODE3_IP>|${NODE3_URL_IP}|g" "$local_file_path"
}

# 依次拉取并渲染所需的核心文件
download_and_render "docker-compose.yml"
download_and_render "patroni/Dockerfile"
download_and_render "patroni/entrypoint.sh"
download_and_render "patroni/patroni.yml"
download_and_render "haproxy/haproxy.cfg"

# 确保启动脚本具备可执行权限
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
echo -e "写库地址 (Primary) : ${CURRENT_URL_IP}:5000"
echo -e "读库地址 (Replica) : ${CURRENT_URL_IP}:5001"
echo -e "监控面板 (HAProxy) : http://${CURRENT_URL_IP}:8404/stats"
echo -e ""
echo -e "查看集群内部角色分配状态，请执行："
echo -e "👉 docker exec -it patroni patronioctl -c /etc/patroni.yml topology"
echo -e "👉 或者使用: docker exec -it patroni python3 -m patroni.patronioctl -c /etc/patroni.yml topology"
echo -e "==============================================\n"