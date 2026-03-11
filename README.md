# PostgreSQL 高可用集群自动化部署方案 (Docker + Patroni)



本项目提供基于 Docker、Patroni、Etcd 和 HAProxy 的 PostgreSQL 高可用（HA）自动化部署方案。特别针对**跨地域、高延迟（约 200ms）网络环境**进行了深度调优，确保集群在极端网络波动下依然稳定，且绝对不发生“脑裂（Split-Brain）”导致的数据损坏。

## ✨ 核心特性

* **全容器化**：所有核心组件（PostgreSQL, Patroni, Etcd, HAProxy）均运行在 Docker 容器中，环境隔离，极简部署。
* **跨区高可用调优**：针对高延迟网络（>100ms），深度优化了 Etcd 的心跳频率与 Patroni 的选举超时机制 (TTL & Retry Timeout)。
* **自动故障转移 (Auto-Failover)**：主节点宕机后，集群会自动在秒级完成新主节点选举，并无缝切换 HAProxy 的流量路由。
* **防脑裂 (Split-Brain Protection)**：基于 Etcd (Raft 共识算法) 和 Patroni 严格状态机，强制要求节点通过分布式锁确认身份，绝对防止数据错乱。
* **动态配置渲染**：无需手动修改配置文件，部署脚本会自动拉取模板并注入真实的集群 IP。

---

## 🚀 快速开始

**前提条件**：准备 3 台已安装 Docker 和 Docker Compose 的 Linux 服务器（推荐 Ubuntu 24.04 / Debian 12 及以上）。

### 推荐方式：`curl` 一键静默部署

无需克隆本仓库，直接在目标机器上执行一行命令即可完成配置生成与容器拉起。

> **语法**:
```bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/pg-ha-docker/main/install.sh | sudo bash -s -- <当前节点ID:1|2|3> <Node1_IP> <Node2_IP> <Node3_IP>
```

**部署演示 (假设三台服务器 IP 分别为 10.0.0.1, 10.0.0.2, 10.0.0.3)：**

**在 Node 1 (10.0.0.1) 上执行：**
```bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/pg-ha-docker/main/install.sh | sudo bash -s -- 1 10.0.0.1 10.0.0.2 10.0.0.3
```

**在 Node 2 (10.0.0.2) 上执行：**
```bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/pg-ha-docker/main/install.sh | sudo bash -s -- 2 10.0.0.1 10.0.0.2 10.0.0.3
```

**在 Node 3 (10.0.0.3) 上执行：**
```bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/pg-ha-docker/main/install.sh | sudo bash -s -- 3 10.0.0.1 10.0.0.2 10.0.0.3
```

*(⚠️ 注意：请将上述命令中的 `<你的用户名>` 替换为实际的 GitHub 账号名)*

**执行完毕后，所有数据和配置将统一生成在 `/opt/docker/pg-ha` 目录下，并在后台启动集群。**

---

## 🔌 端口与访问说明

集群采用**完全对称架构**。部署完成后，无论你的应用连接哪一台机器的 HAProxy 端口，请求都能被正确路由：

* **`5000` 端口**：**写库入口**（HAProxy 会将所有流量自动路由至当前的 Primary 主库）。
* **`5001` 端口**：**读库入口**（HAProxy 会将只读查询通过轮询机制分发给所有的 Replica 从库）。
* **`8404` 端口**：**HAProxy 状态面板**（可通过浏览器访问 `http://<任意节点IP>:8404/stats` 实时查看负载均衡与健康探活状态）。

---

## 🛠️ 日常运维与故障演练指令

集群启动后，你可以使用 `patronioctl` 工具对集群进行管理。以下命令可以在集群中的**任意一台**宿主机上执行：

### 1. 查看集群健康状态与拓扑 (最常用)
实时查看谁是当前的 Leader 主库，谁是从库，以及数据同步的延迟情况（Lag）：
```bash
docker exec -it patroni patronictl -c /etc/patroni.yml list
```

### 2. 手动主从切换 (Failover)
当需要对当前主节点进行停机维护，或进行高可用切换演练时，可安全地手动触发选举：
```bash
docker exec -it patroni patronictl -c /etc/patroni.yml switchover
```
*(⚠️ 注意：根据系统提示进行操作~)*

### 3. 强制重置损坏的从节点
如果某个节点发生严重的物理故障导致数据时间线错乱，你可以强制该节点清空本地旧数据，并从当前 Leader 重新同步全量数据：
```bash
docker exec -it patroni patronictl -c /etc/patroni.yml reinit pg-ha-cluster <节点名>
```
*(⚠️ 注意：请将上述命令中的 `<节点名>` 替换为实际的 node1/2/3 节点名)*
(系统会询问 "Are you sure?"，输入 y 即可)

### 4. 查看组件日志
排查数据库同步异常或选举失败的原因：
* 查看 Patroni 与 PostgreSQL 核心日志:
```bash
cd /opt/docker/pg-ha && docker compose logs -f patroni
```
* 查看 HAProxy 健康检查和路由日志:
```bash
cd /opt/docker/pg-ha && docker compose logs -f haproxy
```

---

## ⚠️ 生产环境安全建议

本项目的模板文件默认使用了弱密码（如 `pgpassword`, `replpassword`）作为示例。在投入真正的生产环境前，**强烈建议**你：
1. Fork 本仓库。
2. 修改 `patroni/patroni.yml` 模板中的 `superuser` 和 `replication` 密码。
3. 将 `install.sh` 中的 `GITHUB_USER` 变量指向你的仓库。