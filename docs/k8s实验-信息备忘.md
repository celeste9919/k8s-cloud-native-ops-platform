# K8s 云原生项目 · 信息备忘（凭证 / 密码 / 密钥 / IP）

> 记录搭建本项目需要记住的所有信息。**仅用于本机实验，请勿外泄。**
> 更新时间：2026-08-25（集群初始化阶段）

---

## 一、节点 & IP 规划（实验网段 172.25.254.0/24，网关 172.25.254.2，DNS 223.5.5.5）

| 角色 | 主机名 | IP | 内存 | 状态 |
|---|---|---|---|---|
| master | k8s-master | 172.25.254.101 | 8G | ✅ 集群1主2从 Ready；Harbor v2.11.1 已装 |
| node1 | k8s-node1 | 172.25.254.102 | 4G | ✅ Ready（已加入集群） |
| node2 | k8s-node2 | 172.25.254.103 | 4G | ✅ Ready（已加入集群） |
| gitlab-server | gitlab-server | 172.25.254.105 | 8G | ✅ GitLab CE 容器运行中（http://172.25.254.105） |
| gitlab-runner | gitlab-runner | 172.25.254.106 | ? | ⏳ 待装 gitlab-runner |

## 二、集群核心信息

- **K8s 版本**：v1.31.0
- **容器运行时**：Docker 29.7.2 + cri-dockerd（-p / run/cri-dockerd.sock）
- **镜像源**：`registry.aliyuncs.com/google_containers`（阿里云）
- **Pod 网段**：10.244.0.0/16（Flannel）
- **Service 网段**：10.96.0.0/12
- **pause 镜像**：`registry.aliyuncs.com/google_containers/pause:3.10`
- **代理**：宿主机 clash `172.25.254.1:7897`（仅下载外网资源临时用；集群内部必须不走代理，用 no_proxy 排除内网段）

## 三、kubectl 连接配置（master 上）

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
```

## 四、加入 worker 节点的命令（kubeadm join）★ 重要，务必保存

```bash
kubeadm join 172.25.254.101:6443 --token 0fc4o7.f8h36b0uakevm9k8 \
        --discovery-token-ca-cert-hash sha256:bb9779bf3c1ada4c99f31416140548dbfbf7c00f9dbcc56169531b995d9dee0f \
        --cri-socket unix:///var/run/cri-dockerd.sock
```

> **token/hash 过期或丢了**，在 master 上重新生成：
> ```bash
> kubeadm token create --print-join-command
> ```

## 五、后续组件密码（预计值，按实际配置填写）

| 组件 | 账号 | 密码 | 用途 |
|---|---|---|---|
| Harbor | admin | 123456（可改） | 私有镜像仓库管理员 |
| Harbor | openlab | A123456a | 普通仓库账号 |

> ✅ **Harbor v2.11.1 已于 2026-08-26 装好**(docker-compose 离线装在 master)。
> 访问地址：**http://172.25.254.101**（HTTP 模式），登录 admin / 123456。
> 注意：因用 HTTP，后续节点 `docker login/push` 前需把 `172.25.254.101` 加进 docker 的 **insecure-registries**。
| MySQL | root | 123456 | 业务数据库 |
| GitLab | root | 初始：Wpx16zwiMa7ikZ/2Gh5ihcz0SzRMjN4Gt0Cs0xejL3w=（24h失效）→ 改：Yunwei#2026A | 代码仓库/CI/CD |

> ✅ GitLab CE 已装（docker 容器跑在 gitlab-server，端口 80/443/2222）：http://172.25.254.105，用户 root。
> ⚠️ 初始 root 密码在容器 /etc/gitlab/initial_root_password，仅 24h 有效，须尽快改。

## 六、母盘 / 克隆环境关键字

- **系统**：RHEL 9.6（Plow）
- **vmset.sh 用法**：`vmset.sh eth0 <IP> <主机名>` → 自动配网关 172.25.254.2 + DNS 223.5.5.5
- **SSH 免密**：root@localhost 已配置（克隆后节点间可免密）
- **环境三禁一装两配套**：禁防火墙 / 禁 swap / 禁 SELinux + 装 Docker+cri-dockerd + 时间同步+hosts
