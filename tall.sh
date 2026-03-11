[1mdiff --git a/README.md b/README.md[m
[1mindex cdef76c..342b3b4 100644[m
[1m--- a/README.md[m
[1m+++ b/README.md[m
[36m@@ -57,23 +57,54 @@[m
 [m
 ### 1. 查看集群健康状态与拓扑 (最常用)[m
 实时查看谁是当前的 Leader 主库，谁是从库，以及数据同步的延迟情况（Lag）：[m
[31m-`docker exec -it patroni patronioctl -c /etc/patroni.yml topology`[m
[32m+[m[32m`docker exec -it patroni curl -s http://localhost:8008/cluster | python3 -c "import sys, json; print(json.dumps(json.load(sys.stdin), indent=4))"`[m
 [m
 ### 2. 手动主从切换 (Failover)[m
 当需要对当前主节点进行停机维护，或进行高可用切换演练时，可安全地手动触发选举：[m
[31m-`docker exec -it patroni patronioctl -c /etc/patroni.yml failover`[m
[31m-*(系统会跳出交互提示，询问你想将哪个 Replica 提拔为新的 Leader)*[m
[32m+[m[32m`docker exec -it patroni curl -i -XPOST http://localhost:8008/switchover \[m
[32m+[m[32m  -H "Content-Type: application/json" \[m
[32m+[m[32m  -d '{"leader": "node2", "candidate": "node3"}'`[m
[32m+[m[41m  [m
[32m+[m[32m执行说明：[m
[32m+[m
[32m+[m[32m- XPOST: 告诉 Patroni 我们要发起一个动作。[m
[32m+[m
[32m+[m[32m- leader: 当前的领袖（node2）。[m
[32m+[m
[32m+[m[32m- candidate: 你想要提拔的新领袖（比如 node3）。[m
[32m+[m
 [m
 ### 3. 强制重置损坏的从节点[m
 如果某个节点发生严重的物理故障导致数据时间线错乱，你可以强制该节点清空本地旧数据，并从当前 Leader 重新同步全量数据：[m
[31m-`docker exec -it patroni patronioctl -c /etc/patroni.yml reinit pg-ha-cluster node<损坏的节点编号>`[m
[32m+[m[32m`docker exec -it patroni curl -i -XPOST http://localhost:8008/reinit \[m
[32m+[m[32m  -H "Content-Type: application/json" \[m
[32m+[m[32m  -d '{"cluster": "pg-ha-cluster", "member": "node<ID>"}'`[m
[32m+[m
[32m+[m[32m🔍 参数深度解析[m
[32m+[m[32m- member: 这是你想要重置的节点名称（例如 node1）。[m
[32m+[m
[32m+[m[32m- 动作逻辑：[m
[32m+[m
[32m+[m[32m   - Patroni 接收到请求后，会先停止该节点上的 PostgreSQL。[m
[32m+[m
[32m+[m[32m   - 它会彻底清空该节点的数据目录 (data_dir)。[m
[32m+[m
[32m+[m[32m   - 随后自动触发 pg_basebackup 或你配置的备份恢复工具，从当前的 Leader 重新拉取全量数据。[m
[32m+[m
[32m+[m[32m- 适用场景：[m
[32m+[m
[32m+[m[32m   - 从库报 Timeline mismatch（时间线不匹配）。[m
[32m+[m
[32m+[m[32m   - 从库数据物理损坏，无法通过 WAL 正常追赶。[m
[32m+[m
[32m+[m[32m   - 你手动在从库乱动了数据，导致主从校验失败。[m
 [m
 ### 4. 查看组件日志[m
 排查数据库同步异常或选举失败的原因：[m
 * 查看 Patroni 与 PostgreSQL 核心日志:[m
[31m-  `cd /opt/docker/pg-ha && docker-compose logs -f patroni`[m
[32m+[m[32m  `cd /opt/docker/pg-ha && docker compose logs -f patroni`[m
 * 查看 HAProxy 健康检查和路由日志:[m
[31m-  `cd /opt/docker/pg-ha && docker-compose logs -f haproxy`[m
[32m+[m[32m  `cd /opt/docker/pg-ha && docker compose logs -f haproxy`[m
 [m
 ---[m
 [m
