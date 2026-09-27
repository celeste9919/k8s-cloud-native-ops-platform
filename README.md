# 云原生自动化运维平台（K8s + CI/CD）

> 基于 **Kubeadm** 搭建 Kubernetes 集群，构建企业级应用容器化部署与自动化运维平台：涵盖 Harbor 私有镜像仓库、NFS 持久化存储、MySQL/Tomcat/Nginx 多服务容器化部署、Ingress 流量路由，以及 GitLab + Runner 的 CI/CD 持续集成流水线，完成**从代码提交到容器部署的自动化闭环**。

## 架构总览

```
                 ┌─────────────── K8s 集群（Kubeadm 1主N从）───────────────┐
用户 ── Ingress ─┤  Nginx(前端/代理)   Tomcat(Java war)   MySQL   ...     │
   (域名路由)    └───────────────────────┬───────────────────────────────┘
                                        │ 拉取镜像
                                  Harbor 私有镜像仓库
                                        ▲ 推送镜像
                        GitLab ──► GitLab Runner（CI/CD 流水线）
用户/应用数据 ── NFS 持久化存储（PV/PVC）
```

**技术栈**：Kubeadm · Kubernetes · Flannel CNI · cri-dockerd · Docker · Harbor · NFS · PV/PVC · ConfigMap · Ingress · ReplicationController/Service · GitLab CE · GitLab Runner · Maven · Shell

**核心能力**
- K8s 集群搭建（Kubeadm 初始化、集群 DNS、kubectl 管理）
- 私有镜像仓库 Harbor（Docker Compose 部署，集群节点拉取验证）
- NFS 持久化存储（PV/PVC 资源清单，容器重启数据不丢）
- 多服务容器化部署（MySQL / Tomcat war / Nginx 前端，ConfigMap 配置反向代理）
- Ingress 域名路由（Nginx-Ingress Controller，`nginx.openlab.com` / `tomcat.openlab.com`）
- GitLab + Runner CI/CD（`.gitlab-ci.yml` 三阶段：Maven 编译 → Docker 打包 → Harbor 推送）

## 目录结构

```
.
├── docs/                          # 学习与实操文档（重点）
│   ├── 项目-从0到1完整命令手册.md    # 操作主线：每步完整命令 + yaml
│   ├── k8s项目执行文档.md           # 命令详解 + 踩坑 + 面试考点
│   ├── k8s项目-避坑直通版.md        # 坑 → 现象 → 根因 → 正确做法 → 口诀
│   ├── 基础命令教学手册.md          # 命令是什么 / 语法 / 含义 / 类比
│   ├── 运维K8s教学引导-通用规范.md   # 教学规范与文档体系
│   ├── k8s实验-信息备忘.md          # 节点/IP/凭证备忘（脱敏使用）
│   └── 项目一-云原生运维平台-面试讲稿.md  # 30秒简介/三层法/STAR/高频题
├── scripts/
│   ├── check_mother.sh            # 母盘环境体检
│   └── node_init.sh               # 节点初始化
└── demo/                          # 示例应用（CI/CD 演练用）
    ├── Dockerfile
    ├── .gitlab-ci.yml
    ├── index.jsp
    ├── WEB-INF/web.xml
    └── demo.war
```

## 踩坑速查（节选）

| 现象 | 根因 | 解决 |
|---|---|---|
| MySQL/Tomcat Pod 长时间 Pending | Flannel CNI 未安装，无法分配 Pod IP | 先装 Flannel 插件再部署 |
| Ingress Controller External-IP 始终 Pending | 裸金属无外部 LoadBalancer | 改用节点 IP + NodePort 暴露 |
| Runner 流水线报 JDK/Maven 未找到 | runner 默认低权限用户 | 改用 root 安装/运行 Runner |
| Worker 节点拉 Harbor 镜像被拒 | Harbor 为 HTTP 协议 | `daemon.json` 加 `insecure-registries` |
| NFS 客户端 mount 失败 | rpcbind 服务未启动 | 启动 rpcbind 并写 `/etc/fstab` |

## 说明

本项目适用于实操学习，文档中的 IP、账号、密码均为**本地虚拟机实验环境**的示例值。
