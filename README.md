# PostgreSQL 高可用集群自动化部署方案 (Docker + Patroni)

本项目提供基于 Docker、Patroni、Etcd 和 HAProxy 的 PostgreSQL 高可用（HA）一键部署方案。特别针对**跨地域、高延迟（约 200ms）网络环境**进行了深度调优，确保集群稳定且不发生“脑裂”。

## ✨ 核心特性

* **全容器化**：所有组件（PG, Patroni, Etcd, HAProxy）均运行在 Docker 中，环境隔离，极简部署。
* **跨区高可用**：针对高延迟网络优化了 Etcd 心跳和 Patroni 选举超时机制。
* **自动故障转移**：主节点宕机后自动选举新主节点并无缝切换 HAProxy 路由。
* **防脑裂 (Split-Brain)**：基于 Etcd 共识算法和 Patroni 严格状态机，绝对防止数据错乱。
* **一键部署**：提供交互式/传参式自动化安装脚本，开箱即用。

## 🚀 快速开始

准备 3 台安装了 Docker 的服务器（Ubuntu/Debian 推荐）。

### 方式：使用一键安装脚本

在每一台服务器上下载并执行 `install.sh`：

```bash
# 语法: bash install.sh <当前节点ID:1|2|3> <Node1_IP> <Node2_IP> <Node3_IP>
```

# 在 Node 1 执行：
```bash
sudo bash install.sh 1 10.0.0.1 10.0.0.2 10.0.0.3
```

# 在 Node 2 执行：
```bash
sudo bash install.sh 2 10.0.0.1 10.0.0.2 10.0.0.3
```

# 在 Node 3 执行：
```bash
sudo bash install.sh 3 10.0.0.1 10.0.0.2 10.0.0.3
```

脚本会自动在 /opt/docker/pg-ha 目录下生成所有配置并启动集群。

🔌 端口说明
集群启动后，无论你连接哪一台机器的 HAProxy，都能正确路由：

5000：读写端口（自动路由至当前的 Primary 主库）

5001：只读端口（轮询负载均衡至当前的 Replica 从库）

8404：HAProxy 状态面板（HTTP 访问查看负载均衡状态）

