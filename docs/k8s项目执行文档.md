# 《云原生自动化运维平台》项目执行文档

> **用途**：边做边记 · 复盘复习 · 面试题库
> **规则**：
> - 命令**首次出现**才详解，后续重复用 `[锚点跳转](#锚点)` 回看第一次的解释
> - `⚠️ 踩坑` = 实操踩过的坑；`⭐ 面试考点` = 面试可能追问的点
> - **排障案例库**（附录A）集中收录所有「问题 → 排查思路 → 根因 → 解决」，复盘/面试都看它

---

## 导航
- [阶段0 环境准备](#阶段0-环境准备)
- [阶段1 集群搭建](#阶段1-集群搭建)
- [阶段2 Harbor 镜像仓库](#阶段2-harbor-镜像仓库)
- [阶段3 NFS 共享存储](#阶段3-nfs-共享存储)
- [阶段4 MySQL 部署](#阶段4-mysql-部署)
- [阶段5 Tomcat 部署](#阶段5-tomcat-部署)
- [阶段6 nginx 部署 + 反代接入层](#阶段6-nginx-部署--反代接入层)
- [附录A 排障案例库](#附录a-排障案例库)
- [附录B 概念扫盲表](#附录b-概念扫盲表)

---

## 阶段0 环境准备

### 0.1 母盘准备
- 母盘 **RHEL 9.6**（基础配置最全的"模板"），VMware Workstation 17.5
- **完整克隆**（非链接克隆），克隆 4 台：master / node1 / node2 / gitlab
- 宿主机 32G 内存 / 32 线程；给 master 8G、node 各 4G、gitlab 8G

### 0.2 虚拟机网络（**全项目关键**）
- 网卡 eth0，VMnet8 NAT
- **网段 `172.25.254.0/24`，网关 `172.25.254.2`，DNS `223.5.5.5`**
- 节点固定 IP：
  - k8s-master `172.25.254.101`
  - k8s-node1 `172.25.254.102`
  - k8s-node2 `172.25.254.103`
  - gitlab `172.25.254.105`
- 代理（宿主机走 Clash 7897）：**终端级临时变量**，只在"下载外网"用；**集群内部禁走代理**

⚠️ 踩坑：DNS 误写成 `233.5.5.5`（应为 `223.5.5.5`）→ `sed` 修正。
⭐ 面试考点：**为什么代理要反复 export？** —— export 是**当前终端窗口的临时变量**，新窗口自动清零；代理对集群内部有害（kubeadm init 报 HTTPProxyCIDR、docker pull 报 EOF）。正确姿势"临时用、用完 unset"。

### 0.3 三禁一装
- 禁用 **SELinux**、**防火墙**、**swap**（交换分区，非内存）
- 装基础工具（yum 常用包）

---

## 阶段1 集群搭建

### 1.1 Docker + cri-dockerd
`cri-dockerd` 是 **"翻译官"**：K8s(kubelet) 只说 CRI 语言，docker 只说 Docker 语言，cri-dockerd 把两者翻译对接。Docker 本身不直接支持 K8s 的标准 CRI 接口。

### 1.2 kubeadm / kubelet / kubectl 三件套
- `kubeadm`：**生**（初始化集群）
- `kubelet`：**养**（每台节点常驻守护进程，管容器）
- `kubectl`：**指挥**（发命令给集群）

### 1.3 kubeadm init（改镜像源 + 网段 + cri-socket）
```bash
kubeadm init \
  --apiserver-advertise-address=172.25.254.101 \
  --image-repository registry.aliyuncs.com/google_containers \
  --kubernetes-version v1.31.0 \
  --pod-network-cidr=10.244.0.0/16 \
  --cri-socket=unix:///var/run/cri-dockerd.sock
```

[详解]
- `--apiserver-advertise-address`：master 的 API Server 对外 IP
- `--image-repository`：改镜像源（国内用 `registry.aliyuncs.com/google_containers`）
- `--pod-network-cidr`：Pod 网段（`10.244.0.0/16`，**必须和网络插件一致**）
- `--cri-socket`：**指向 cri-dockerd 的通信口**（socket），`unix:///var/run/cri-dockerd.sock`
- `--pod-network-cidr` 与 cgroup 无关，**换网络插件时要一致**

### 1.4 Flannel 网络插件
```bash
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
```
镜像 `docker.io/flannel/flannel:v0.25.6`；**Pod 网段必须 `10.244.0.0/16`**（和 init 一致）。

⚠️ 踩坑：Flannel 起了但 `CrashLoopBackOff` → **附录A-01**（br_netfilter）
⭐ 面试考点：**Flannel→br_netfilter 故障**（完整 STAR 见附录A-01）

### 1.5 节点加入(join)
```bash
kubeadm join 172.25.254.101:6443 --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:bb9... \
  --cri-socket unix:///var/run/cri-dockerd.sock
```
⚠️ 踩坑：join 报 `Found multiple CRI endpoints` / `token invalid` → **附录A-02 / A-03**
💡 join 命令**别手抄**，用 `kubeadm token create --print-join-command` 让 master 生成后**整条原样复制**。

---

## 阶段2 Harbor 镜像仓库

Harbor 是**私有镜像仓库**（存镜像，供集群节点推/拉）。
- 装 **docker-compose v2.29.1**（Harbor 约 10 个容器，依赖复杂，必须用 compose 一键管理）
- 下载离线包 `harbor-offline-installer-v2.11.1.tgz` → 解压 → `cp harbor.yml.tmpl harbor.yml`
- 改 `harbor.yml`：hostname=172.25.254.101 / harbor_admin_password / data_volume
- `./prepare` → `./install.sh`
- 访问 `http://172.25.254.101`，建 **openlab 项目**

前提：node 的 `/etc/docker/daemon.json` 必须含 `insecure-registries: 172.25.254.101`（否则 push 走 443 被拒）。

[详解] **docker vs docker-compose**：docker 管单个容器（砌砖工人）；docker-compose 管一组容器（施工总包，yml 定义、up 一键拉起）。
⚠️ 踩坑：prepare 报 https 错误 → **附录A-04**；push 报 :443 / :80 refused / no basic auth → **附录A-05/06/07**
⭐ 面试考点：**为什么要 insecure-registries** —— docker 默认只信 https 仓库，Harbor 是 http(80)，不信任就拒绝；加上 `--insecure-registries` 后 docker 才肯用明文连。

---

## 阶段3 NFS 共享存储

NFS 是**分布式共享文件系统**，给集群多个节点共享一份数据（配合 PV/PVC）。

**master（NFS 服务端）**：
```bash
yum install nfs-utils rpcbind nfs-server
mkdir -p /data/k8s/mysql /data/k8s/tomcat /data/k8s/nginx/html /data/k8s/nginx/nginx
cat >/etc/exports
/data/k8s 172.25.254.0/24(rw,sync,no_root_squash,no_all_squash)
exportfs -rv          # 重新导出（新目录必须重新导出！）
showmount -e localhost
```

[详解] **`exportfs -rv`**：NFS 服务端靠一份"导出清单(exports)"对外提供目录；**新建目录后必须重新导出**，客户端(nodes)才知道它存在。`-r`=re-export(重新导出)、`-v`=verbose(显示过程)。类比：新房间要登记进"访客名单"，不然访客敲门会说"没这个房间"。

**node（客户端）**：
```bash
mount -t nfs 172.25.254.101:/data/k8s /data/nfs
echo ... >> /etc/fstab     # 开机自动挂载
```
⚠️ 踩坑：nginx 挂载失败「No such file or directory」→ **附录A-11**（目录没建/没导出）

---

## 阶段4 MySQL 部署

四个关键资源（**PV/PVC/RC/Service**）：
| 资源 | 作用 | 类比 |
|---|---|---|
| **PV** | 物理存储(指向 NFS) | 仓库货架 |
| **PVC** | 申请存储 | 领货单(申请) |
| **RC** | 副本控制器 | 工头 |
| **Service** | 稳定入口 | 固定电话 |

**镜像**推送到 Harbor openlab 项目：`172.25.254.101/openlab/mysql:8.4.2`
**yaml**：RC(副本1) + Service(NodePort 30361) + PV(10Gi RWX 指向 /data/k8s/mysql) + PVC(Bound)
**验证**：`kubectl exec` 进 Pod 建 testdb → `kubectl delete pod` → RC 自愈重建 → testdb 仍在（**持久化验证成功**）。

[详解] `kubectl delete pod` 后 **RC 会自动拉起一个新 Pod**（副本自愈）；数据在 NFS 里，删 Pod 不丢 → 证明**持久化**。

---

## 阶段5 Tomcat 部署

- 镜像 `172.25.254.101/openlab/tomcat:10.1.30`；env 传 `MYSQL_SERVICE_HOST=mysql` / `MYSQL_SERVICE_PORT=3306`
- RC + Service(NodePort 30001) + PV/PVC(5Gi 指向 /data/k8s/tomcat)
- 挂载 `/usr/local/tomcat/webapps`（web 应用目录）
- 部署 `demo.war`（Java Web 演示应用）

⚠️ 踩坑：tomcat Pod 卡 `ImagePullBackOff` → **附录A-08**（node 未登录 Harbor，私有镜像需凭证）
[详解] `kubectl cp demo.war <pod>:/usr/local/tomcat/webapps/`：容器有**独立隔离文件系统**（Linux namespace + OverlayFS），宿主机 `cp` 进不去容器，`kubectl cp` 是**跨隔离墙的桥**。

---

## 阶段6 nginx 部署 + 反代接入层

### 6.1 nginx 静态 web（RC）
- 镜像 `172.25.254.101/openlab/nginx:1.27.1`；RC + Service(NodePort 30002) + PV/PVC(3Gi)
- **subPath 技巧**：同一个 PVC(nginx) 挂到容器**两个位置**：`/usr/share/nginx/html`(网页根目录) + `/etc/config`(配置目录)，用 `subPath: html` / `subPath: nginx` 分别指向两个子目录。

[详解] **subPath**：同一个存储挂到容器不同目录时，用 subPath 指定 PVC 里的不同子路径。nginx 把"网页(html) + 配置(nginx)"分开存在 NFS 的同一 PV 下。

### 6.2 nginx 反代接入层（Deployment + ConfigMap）
**ConfigMap** = K8s 的"配置盒子"（存配置/小文件，挂载进容器当配置文件用，改配置不用改镜像）。

`nginx-proxy-cm.yaml`：两个 ConfigMap
- `nginxconf`（反代配置 default.conf）
- `nginx-index`（测试页 index.html）

`nginx-proxy.yaml`：Deployment `open-nginx-proxy`，镜像 nginx:1.27.1，挂载两个 ConfigMap：
- nginxconf → `/etc/nginx/conf.d`（反代配置）
- nginx-index → `/usr/share/nginx/html`（index.html）

**反代路由（统一入口）**：
| 路径 | 转发到 |
|---|---|
| `/nginx` | `nginx-svc` |
| `/tomcat` | `tomcat-svc:8080` |
| `/` | 本地 html(indext.html) |

`kubectl expose deployment open-nginx-proxy --port=80` → 生成 Service。

[详解] **正向代理 vs 反向代理**：反向代理里**客户端不知道后端是谁**，只认这个入口，nginx 背后把请求偷偷转发出去 → **统一入口**（对外只暴露一个地址，内部随便路由）。
[详解] **Deployment vs RC**：RC 老式副本管理；Deployment 更现代（支持滚动更新/回滚），`apps/v1`。
⚠️ 踩坑：nginx Pod 卡 `ContainerCreating` → **附录A-11**（NFS 目录未导出）
⭐ 面试考点：**什么是 ConfigMap / 为什么用 ConfigMap** —— 配置与镜像解耦，改配置不用重建镜像。

**✅ 验证（统一入口打通）**：
- `kubectl get svc` → 新增 `open-nginx-proxy ClusterIP 80/TCP`
- `curl <反代PodIP>` → `Hello Nginx, This is Nginx Web Page`（命中 `location /` 本地 html）
- `curl <反代PodIP>/tomcat/demo/` → `Hello, Demo App!`（命中 `/tomcat` → `tomcat-svc:8080` → demo 应用）
- **⭐ 判断反代是否成功的标准**：看返回的错误页**是谁发的**。若 404/403 是**后端自己发**（Tomcat/nginx 的页面）→ 流量已到后端=**转发成功**；若 nginx 反代返回 **502 Bad Gateway** → 反代失败（proxy_pass 连不上/解析不了）。
- **完整链路**：`入口(open-nginx-proxy) → nginx 反代 → tomcat-svc → Tomcat` 全通

---

## 附录A 排障案例库

> **通用排查思路（四步）**：① 看现象（`kubectl get pod`）→ ② 看事件（`kubectl describe` / `kubectl logs`）→ ③ 定位根因（event/log 里那行报错）→ ④ 对应修复。**面试讲案例按这个步骤，逻辑最清晰。**

### A-01 Flannel CrashLoopBackOff → 缺 br_netfilter
- **现象**：kube-flannel Pod `CrashLoopBackOff`（已重启5次），master 却 Ready
- **定位**：看日志
  `kubectl describe pod -n kube-flannel <pod>` / `kubectl logs`
  → `Failed to check br_netfilter: stat /proc/sys/net/bridge/bridge-nf-call-iptables: no such file or directory`
- **根因**：master 内核**缺 `br_netfilter` 模块**，桥接流量无法被 iptables 处理（flannel 依赖它转发 Pod 间流量）
- **排查思路**：现象(重启) → 描述事件(describe) → 日志(报错关键字) → 定位缺模块 → 修复
- **解决**：
  ```bash
  modprobe br_netfilter
  sysctl -w net.ipv4.ip_forward=1
  sysctl -w net.bridge.bridge-nf-call-iptables=1
  sysctl -w net.bridge.bridge-nf-call-ip6tables=1
  cat >/etc/sysctl.d/k8s.conf      # 持久化
  echo br_netfilter >/etc/modules-load.d/k8s.conf
  sysctl --system
  kubectl rollout restart daemonset kube-flannel-ds -n kube-flannel
  ```
- **⭐ 面试 STAR**（3分钟版）："主节点初始化后 flannel 一直重启，我用 describe 看事件、看日志，发现报 `br_netfilter` 相关错误，判断是缺内核模块和内核参数没开，加载模块 + 开三个内核参数后 flannel 正常，集群 Ready。**排查靠的是'先看事件和日志，别猜'**。"

### A-02 join 报 Found multiple CRI endpoints
- **现象**：`Found multiple CRI endpoints on the host`（检测到 containerd.sock + cri-dockerd.sock 两个）
- **根因**：主机上同时有 containerd 和 cri-dockerd 两套 CRI socket，kubeadm 不知道用哪个
- **解决**：join 命令补 `--cri-socket unix:///var/run/cri-dockerd.sock`

### A-03 join 报 token invalid
- **现象**：`the bootstrap token is invalid`
- **根因**：复制 join 命令时**丢了字符**（token 前半段应 6 位，如 aju3z vs ajuf3z）
- **解决**：master 重新生成 `kubeadm token create --print-join-command`，**整条原样复制**（别手抄！）

### A-04 Harbor prepare 报 https 错误
- **现象**：`./prepare` → `The protocol is https but attribute ssl_cert is not set`
- **根因**：用的是原始模板，https 块没注释（http 模式不需要 https 证书）
- **解决**：`sed` 注释掉 harbor.yml 的 https 块（13行 https / 15行 port:443 / 17行 certificate / 18行 private_key），重新 prepare

### A-05 push 报 :443 connection refused
- **现象**：master `docker push` → `dial tcp 172.25.254.101:443: connect: connection refused`
- **根因**：node 的 `/etc/docker/daemon.json` **没配 insecure-registries**，docker 默认走 443(https) 连 Harbor，而 Harbor 是 http(80)
- **解决**：daemon.json 加 `insecure-registries: ["172.25.254.101"]` + `systemctl restart docker`

### A-06 push 报 :80 connection refused（Harbor 后端不健康）
- **现象**：修好 443 后仍 `dial tcp 172.25.254.101:80: connect: connection refused`
- **定位**：`curl -s http://172.25.254.101` 返回 502（不是 200）→ Harbor 后端 nginx 不健康
- **根因**：Harbor 容器(docker-compose)健康状态异常
- **解决**：`cd /data/server/harbor/harbor && docker-compose up -d`（幂等，补健康容器）→ curl 200
- **⭐ 面试**：容器化应用健康检查 + docker-compose 管理的服务如何排查（docker-compose ps / logs）

### A-07 push 报 no basic auth credentials
- **现象**：`no basic auth credentials`
- **根因**：这台机器**从未 `docker login` 过 Harbor**（push 必须登录）
- **解决**：`docker login 172.25.254.101`（输账号密码）

### A-08 tomcat Pod ImagePullBackOff / 私有镜像需凭证
- **现象**：tomcat Pod `ImagePullBackOff` → `no basic auth credentials`
- **根因**：**node1 没登录 Harbor**，而私有项目(openlab)拉镜像需凭证
- **解决**：node1 `docker login 172.25.254.101`
- **⭐ 面试**：**push vs pull 认证规则** —— push 一律要登录；pull 公开项目免登录、**私有项目要登录**。

### A-09 kubectl 报 localhost:8080 refused
- **现象**：重启虚拟机后 `The connection to the server localhost:8080 was refused`
- **根因**：`export KUBECONFIG=...` 是**终端级临时变量**，重启丢失；kubectl 找不到配置默认连 localhost:8080
- **解决**：`export KUBECONFIG=/etc/kubernetes/admin.conf` + 写入 `~/.bashrc`（`echo 'export KUBECONFIG=...' >> ~/.bashrc`）持久化，以后新终端自动加载，**不用每次修复**

### A-10 node2 daemon.json 为空（node_init.sh 顺序隐患）
- **现象**：node2 的 daemon.json 是空的 → docker 配置丢失
- **根因**：初始化脚本**先拷 master 的 daemon.json、后装 docker，装 docker 时覆盖成空**
- **解决**：重建三合一 daemon.json（registry-mirrors + insecure-registries + systemd cgroup）
- **改进**：脚本顺序改为**先装 docker、再配 daemon.json**

### A-11 nginx Pod 卡 ContainerCreating → NFS 目录未导出
- **现象**：nginx Pod 持续 `ContainerCreating`（2 天），mysql/tomcat 正常
- **定位**：`kubectl describe pod nginx-xxx` → Events：
  `MountVolume.SetUp failed ... mount failed: exit status 32`
  `mount.nfs: mounting 172.25.254.101:/data/k8s/nginx failed, reason given by server: No such file or directory`
- **根因**：**NFS 服务器(master)上 `/data/k8s/nginx` 目录没建/没导出**（mysql/tomcat 的目录之前建过，nginx 的是后加的）
- **解决**：
  ```bash
  mkdir -p /data/k8s/nginx/html /data/k8s/nginx/nginx
  exportfs -rv          # 关键：重新导出！
  showmount -e localhost
  ```
  之后 kubelet 自动重试挂载（2分钟/次），Pod 自动变 Running，**不用重启 Pod**。
- **⭐ 面试 STAR**："POD 一直 ContainerCreating，describe 看事件发现 NFS 挂载报 No such file，判断是 NFS 服务端目录没建/没 exportfs，建目录 + exportfs -rv 后自动恢复。**教训：NFS 新共享目录必须重新 exportfs**。"

---

## 附录B 概念扫盲表

### B-1 kubectl get 的资源区别
| 命令 | 看什么 |
|---|---|
| `kubectl get all` | 所有常见资源(Pod/RC/Service)一次全看 |
| `kubectl get pod` | 只看 Pod(容器组) |
| `kubectl get pv,pvc` | 逗号分隔看多类；这里看存储(PV+PVC) |
| `kubectl get nodes` | 节点(几台机器) |

**常用参数**：`-o wide`(展开更多列) · `-n 命名空间`(只查某命名空间) · `-A`(所有命名空间)

### B-2 `-f` 是什么
`-f` = file(文件)，`kubectl create -f nginx.yaml` = 从这个文件读配置创建资源（"按图纸施工"）。对 create/apply/delete 都通用。

### B-3 `-o wide`
`-o` = output；`-o wide` = 宽格式，多显示几列(Pod 看 IP/所在节点)。还支持 `-o yaml/json/name`。

### B-4 为什么 push 前要 tag
镜像的名字决定它属于哪个仓库。`docker tag nginx:1.27.1 172.25.254.101/openlab/nginx:1.27.1` 给同一镜像贴"完整仓库地址"的新名字；`docker push` 按名字推送。tag 不改内容，只改名字(地址)。

### B-5 docker / docker-compose
docker 管单个容器；docker-compose 管一组容器(yml 定义、up 一键拉起)。新版 `docker compose`(空格)= 旧版 `docker-compose`(横杠)。

### B-6 nginx 静态 web vs 反代接入层
静态 web(RC, subPath 挂 NFS) 提供网页；反代接入层(Deployment, ConfigMap 配 proxy_pass) 按路径转发到不同后端 → 统一入口。

### B-7 为什么 PV 要用 RWX / Retain
RWX=多节点读写(共享)；Retain=删除 PVC 时保留 PV 数据(回收策略)。

### B-8 `kubectl cp`
跨"容器隔离墙"拷贝文件（宿主机 cp 进不去容器文件系统）。

### B-9 `apply vs create`
`create` 只创建(重复会报已存在)；`apply` 创建或更新(幂等)。ConfigMap/Deployment 用 apply 更合适。

---

> 完 —— 持续追加中。每完成一步，把该步命令/详解/踩坑/考点按模板填入对应阶段。
