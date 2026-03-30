# PostgreSQL 高可用集群自动化部署方案 (Docker + Patroni)
本项目提供基于 Docker、Patroni、Etcd 和 HAProxy 的 PostgreSQL 终极高可用（HA）自动化部署方案。全面拥抱云原生，具备 IPv4/IPv6 双栈兼容、跨国网络自适应调优 以及 防爆盘日志免疫 等企业级特性，确保集群在极其恶劣的网络环境下依然稳如泰山。

## ✨ 核心特性 (Architecture Highlights)
- 🌍 跨国自适应网络引擎 (Auto-Tuning)：部署脚本内置网络探针，自动计算节点间的最大物理延迟，并动态注入最完美的 Etcd/Patroni 共识超时参数，从根源上杜绝高延迟引发的“脑裂 (Split-Brain)”。

- 🌐 纯血双栈兼容 (IPv4/IPv6)：所有组件底层网络均经过特殊改造，完美支持纯 IPv4、纯 IPv6 或双栈混用的 VPS 及宿主机。

- 🛡️ 磁盘免疫策略：全局注入 Docker 日志轮转机制（限制单容器最大 150MB），彻底根治 HAProxy 高频健康检查带来的垃圾日志风暴，保护小容量机器不被撑爆。

- ⚡ 读写分离与高可用 (Auto-Failover)：主节点物理宕机后，集群秒级完成新主节点选举；HAProxy 实时感知拓扑变化，无缝进行读写流量路由（端口 5000 写，5001 读）。

- 🔒 强一致性引导部署：采用“主节点生成，从节点继承”的凭证下发机制，确保整个分布式集群的安全密码与时间线判定绝对一致。

## 🚀 部署指南 (Quick Start)
前提条件：准备 3 台已安装 Docker 和 Docker Compose 的 Linux 服务器。

⚠️ 【极其重要】部署顺序不可逆！：为了防止集群因参数不一致导致脑裂，必须先完整部署 Node 1，再使用 Node 1 生成的“共识参数”去部署 Node 2 和 Node 3。

### 📌 步骤一：部署主导节点 (Node 1)
在 Node 1 机器上执行以下命令（替换 <你的用户名> 及实际 IP）：

```Bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/pg-ha-docker/main/install.sh | sudo bash -s -- 1 <Node1_IP> <Node2_IP> <Node3_IP>
```
执行过程中，脚本会自动探测网络延迟。部署成功后，屏幕底部会用红字高亮打印出一组【集群共识网络参数与凭证】。请务必完整复制或截图保存这些参数！

### 📌 步骤二：部署跟随节点 (Node 2 & Node 3)
拿着刚才从 Node 1 复制的红字参数，依次在 Node 2 和 Node 3 上执行部署命令：

在 Node 2 上执行：

```Bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/pg-ha-docker/main/install.sh | sudo bash -s -- 2 <Node1_IP> <Node2_IP> <Node3_IP>
```
在 Node 3 上执行：

```Bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/pg-ha-docker/main/install.sh | sudo bash -s -- 3 <Node1_IP> <Node2_IP> <Node3_IP>
```
执行时，脚本会拦截并提示您依次输入数据库密码以及 ETCD_ELECTION_TIMEOUT 等网络超时参数。严格填入后，集群将完成完美的时钟与共识对齐！

(执行完毕后，所有数据和配置将统一生成在 /opt/docker/pg-ha 目录下。)

## 🔌 端口与访问说明
集群采用完全对称架构。部署完成后，无论你的应用连接哪一台机器的 HAProxy 端口，请求都能被精准路由（支持 IPv4 及 [IPv6] 访问）：

- 5000 端口：写库入口（自动路由至当前存活的 Primary 主库）。

- 5001 端口：读库入口（轮询分发给所有的 Replica 从库，大幅提升并发查询能力）。

- 8404 端口：状态面板（浏览器访问 http://<任意节点IP>:8404/stats 实时查看负载均衡与健康探活状态）。

## 🛠️ 日常运维与故障演练指令
以下命令可以在集群中的任意一台宿主机的 /opt/docker/pg-ha 目录下执行：

1. 查看集群健康状态与拓扑 (最常用)
实时查看谁是当前的 Leader 主库，谁是从库，以及数据同步的延迟情况（Lag）：

```Bash
docker exec -it patroni patronictl -c /etc/patroni.yml list
```
2. 手动主从切换 (Failover)
当需要对当前主节点进行停机维护，或进行高可用切换演练时，可安全地手动触发选举：

```Bash
docker exec -it patroni patronictl -c /etc/patroni.yml switchover
```
(⚠️ 操作提示：1. 确认当前运行的主节点并回车 -> 2. 输入准备提拔的新主节点名并回车 -> 3. 输入 y 确认执行。)

3. 强制重置损坏的从节点
如果某个节点发生严重的物理故障导致数据时间线错乱，可强制该节点清空本地旧数据，并从当前 Leader 重新同步全量数据：

```Bash
docker exec -it patroni patronictl -c /etc/patroni.yml reinit pg-ha-cluster <损坏的节点名>
```
4. 查看组件诊断日志
查看 Patroni 与 PostgreSQL 核心运行日志:

```Bash
docker compose logs -f patroni
```
查看 HAProxy 健康检查和路由日志:

```Bash
docker compose logs -f haproxy
```
