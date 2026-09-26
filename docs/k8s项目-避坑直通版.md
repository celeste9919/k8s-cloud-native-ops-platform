# 《云原生自动化运维平台》避坑直通版（速查手册）

> **用途**：重来一遍直接通 / 当作面试急查
> **规则**：只记「坑 → 现象 → 根因 → 正确做法 → 口诀」，每个 3-5 行，一眼看懂
> **⭐** = 面试可讲成排障/避坑案例（STAR 素材）
> 与《k8s项目执行文档》（边做边记、完整版）配合：执行文档看"怎么做"，本手册看"别踩什么"。

---

## 阶段0 环境准备

- **坑 0.1  DNS 写错**
  - 现象：ping 外网不通
  - 根因：DNS 误写 `233.5.5.5`（应 `223.5.5.5`）
  - 正确：`nmcli c modify eth0 ipv4.dns 223.5.5.5` → `nmcli c up eth0`
  - 口诀：**DNS 是 223.5.5.5（阿里），不是 233**
- **坑 0.2  代理 export 只管当前窗口**
  - 现象：换了窗口 curl 又走代理/卡；集群内部 kubectl/docker 报错
  - 根因：`export http_proxy` 是**终端级临时变量**，新窗口清零
  - 正确：临时用、用完 `unset`；集群内部必须 `no_proxy` 排除内网段
  - 口诀：**代理临时用，集群内部禁走；export 只活一个窗口**
- **坑 0.3  网卡名不确定**
  - 现象：`nmcli c modify eth0` 报找不到
  - 根因：母盘网卡可能是 `eth0` 或 `ens160`
  - 正确：先 `ip link` 看真实网卡名，再改
  - 口诀：**先 ip link 看网卡名，再 nmcli 改**

---

## 阶段1 集群搭建

- **坑 1.1  ⭐ Flannel CrashLoopBackOff**
  - 现象：kube-flannel 无限重启(5次)，master 却 Ready
  - 根因：内核**缺 `br_netfilter` 模块** + 内核参数没开
  - 正确：`modprobe br_netfilter` + `sysctl` 开 `ip_forward`/`bridge-nf-call-iptables`/`ip6tables` + 写 `/etc/sysctl.d/k8s.conf` + `echo br_netfilter >/etc/modules-load.d/k8s.conf` + `sysctl --system` + `rollout restart daemonset`
  - 口诀：**flannel 起不来 → 先查 br_netfilter**
- **坑 1.2  join 报 multiple CRI endpoints**
  - 现象：`Found multiple CRI endpoints on the host`
  - 根因：同时有 containerd.sock + cri-dockerd.sock
  - 正确：join 补 `--cri-socket unix:///var/run/cri-dockerd.sock`
  - 口诀：**dual CRI 就指定 cri-socket**
- **坑 1.3  join 报 token invalid**
  - 现象：`the bootstrap token is invalid`
  - 根因：复制 join 命令**丢了字符**（token 前半段应 6 位）
  - 正确：master 重新 `kubeadm token create --print-join-command`，**整条原样复制**
  - 口诀：**join 命令别手抄，整条复制**
- **坑 1.4  --cri-socket 指向误**
  - 现象：init 报错
  - 根因：`--cri-socket` 指 cri-dockerd **通信口(socket)**，`--apiserver-advertise-address` 才指 master IP
  - 正确：`--cri-socket=unix:///var/run/cri-dockerd.sock`
  - 口诀：**cri-socket 给 socket，advertise 才给 IP**
- **坑 1.5  换网络插件网段要一致**
  - 现象：Pod 网络不通
  - 根因：`--pod-network-cidr` 与网络插件不一致（与 cgroup 无关）
  - 正确：init 与 flannel yaml 都用 `10.244.0.0/16`
  - 口诀：**Pod 网段，init 和插件必须一致**

---

## 阶段2 Harbor

- **坑 2.1  prepare 报 https 错误**
  - 现象：`./prepare` → `protocol is https but ssl_cert not set`
  - 根因：原始模板 https 块没注释（http 模式不需要证书）
  - 正确：`sed` 注释 harbor.yml 的 https 块（13/15/17/18 行）
  - 口诀：**http 模式，注释掉 https 块**
- **坑 2.2  ⭐ push 报 :443 refused（没信任 http）**
  - 现象：`docker push` → `dial tcp :443: connect: connection refused`
  - 根因：docker 默认只信 https，Harbor 是 http(80)，没配 insecure
  - 正确：daemon.json 加 `insecure-registries: ["172.25.254.101"]` + restart docker
  - 口诀：**http 仓库必须加 insecure-registries**
- **坑 2.3  push 报 :80 refused / 502（Harbor 不健康）**
  - 现象：修好 443 后仍 refused，curl 返回 502
  - 根因：Harbor docker-compose 容器健康状态异常
  - 正确：`cd /data/server/harbor/harbor && docker-compose up -d` → curl 200
  - 口诀：**Harbor 不健康 → docker-compose up -d**
- **坑 2.4  push 报 no basic auth**
  - 现象：`no basic auth credentials`
  - 根因：这台机器没 `docker login` 过 Harbor（push 必须登录）
  - 正确：`docker login 172.25.254.101`
  - 口诀：**push 前必 login**
- **坑 2.5  重启后 Harbor 起不来**
  - 现象：重启虚拟机后 curl Harbor 80 refused
  - 根因：docker-compose 容器健康没自动恢复（等一会或未起）
  - 正确：**等 1-2 分钟** → 不行再 `docker-compose up -d`
  - 口诀：**重启后 Harbor 等一会 + up -d 兜底**

---

## 阶段3 NFS

- **坑 3.1  ⭐ nginx Pod ContainerCreating（NFS 目录没导出）**
  - 现象：nginx Pod 一直 ContainerCreating，mysql/tomcat 正常
  - 根因：`mount.nfs ... No such file or directory` = **NFS 服务端目录没建/没 export**
  - 正确：`mkdir -p /data/k8s/nginx/html /data/k8s/nginx/nginx` + **`exportfs -rv`** + `showmount -e`，kubelet 自动重试挂载
  - 口诀：**NFS 新目录必须 exportfs -rv，否则挂载 No such file**
- **坑 3.2  只 mkdir 不 exportfs**
  - 现象：建了目录客户端仍挂不上
  - 根因：NFS 靠"导出清单"对外，新目录没重新导出
  - 正确：`exportfs -rv`（重新导出）必跑
  - 口诀：**mkdir 后跟 exportfs -rv**

---

## 阶段4/5 应用（MySQL / Tomcat）

- **坑 4.1  ⭐ tomcat ImagePullBackOff**
  - 现象：tomcat Pod `ImagePullBackOff` → `no basic auth credentials`
  - 根因：**node 没 docker login**，私有项目(openlab)拉镜像需凭证
  - 正确：node `docker login 172.25.254.101`
  - 口诀：**私有镜像拉取，节点要 login**
- **坑 4.2  node_init.sh 顺序**
  - 现象：node2 的 daemon.json 为空
  - 根因：脚本**先拷 daemon.json、后装 docker**，装 docker 时把配置覆盖成空
  - 正确：**先装 docker、再配 daemon.json**
  - 口诀：**先装 docker 再配 daemon.json**
- **坑 4.3  kubectl cp vs cp**
  - 现象：宿主 `cp` 进容器失败
  - 根因：容器文件系统隔离（namespace + OverlayFS），宿主 cp 进不去
  - 正确：用 `kubectl cp`（跨隔离墙的桥）
  - 口诀：**进容器用 kubectl cp**
- **坑 4.4  重启后 kubectl localhost:8080 refused**
  - 现象：重启后 `The connection to the server localhost:8080 was refused`
  - 根因：`export KUBECONFIG` 重启丢失，kubectl 默认连 localhost:8080
  - 正确：写进 `~/.bashrc`（自动加载，不用每次修）
  - 口诀：**KUBECONFIG 写进 ~/.bashrc 持久化**

---

## 阶段6 nginx 接入层

- **坑 6.1  ⭐ 怎么判断反代成功**
  - 现象：curl 返回 404/403，以为失败
  - 根因：**404/403 是后端自己发**（Tomcat/nginx）= 流量已到后端=**转发成功**；只有 **502** 才是反代失败（proxy_pass 连不上）
  - 正确：看错误页是谁发的；`/tomcat/demo/` 返 demo 内容 = 全通
  - 口诀：**后端自己的 404 = 成功；nginx 反代的 502 = 失败**
- **坑 6.2  ConfigMap 用 apply**
  - 现象：create 报已存在
  - 根因：ConfigMap/Deployment 可创建可更新
  - 正确：用 `kubectl apply`（幂等）
  - 口诀：**ConfigMap/Deploy 用 apply**
- **坑 6.3  客户端访问用 IP 不用主机名**
  - 现象：浏览器跳 gitlab-server 主机名无法解析
  - 根因：宿主机/客户端不认主机名
  - 正确：用 `http://172.25.254.105`（IP）访问；或加 hosts
  - 口诀：**访问用 IP，主机名要进 hosts**

---

## 阶段7 CI/CD（本次最硬核）

- **坑 7.1  gitlab-ce 镜像名要带 namespace**
  - 现象：`docker pull gitlab-ce` → `repository does not exist`
  - 根因：GitLab 在 docker hub 组织 `gitlab` 下，完整名 `gitlab/gitlab-ce`
  - 正确：`docker pull gitlab/gitlab-ce:latest`
  - 口诀：**gitlab 镜像必须带 gitlab/ 前缀**
- **坑 7.2  ⭐ 镜像"不在白名单"**
  - 现象：`this image is not in the allow list`（daocloud 加速器拒）
  - 根因：daocloud 只转发它白名单内的镜像，gitlab-ce 不在
  - 正确：换源（代理/其他加速器）
  - 口诀：**某些加速器有白名单，拉不了就换源/走代理**
- **坑 7.3  docker 拉镜像要配 dockerd 的代理**
  - 现象：配了终端 export 代理，docker pull 还是失败
  - 根因：`docker pull` 是 **dockerd 守护进程**拉的，不读终端 export
  - 正确：配 `/etc/systemd/system/docker.service.d/http-proxy.conf`（HTTP_PROXY/HTTPS_PROXY/NO_PROXY）+ `daemon-reload` + `restart docker`
  - 口诀：**docker 走代理要配 systemd，终端 export 不管用**
- **坑 7.4  clash 全局 ≠ docker 走代理**
  - 现象：切了 clash 全局，docker 还是连不上 docker hub
  - 根因：clash 全局只管宿主机流量；**docker daemon 要单独配代理**
  - 正确：docker 单独配 http-proxy.conf；`systemctl show docker | grep -i proxy` 确认
  - 口诀：**clash 全局 ≠ docker 代理，docker 要单独配**
- **坑 7.5  register 用 --registration-token**
  - 现象：`--token` 报 `verify ... 403 / use '-r' instead of '-t'`
  - 根因：`--token`=验证已注册 runner；`--registration-token`(-r)=注册新 runner
  - 正确：用 `--registration-token`
  - 口诀：**-r 注册、-t 验证，别混**
- **坑 7.6  ⭐ token 别从对话复制（省略号坑）**
  - 现象：runner 一直 403，token 是 `glrtr-...dq8S`（中间省略）
  - 根因：对话里 token 可能被省略显示，复制过去残缺
  - 正确：**用 `gitlab-runner register` 自己生成的完整 token，或从 GitLab 界面复制**
  - 口诀：**token 让 gitlab-runner 自己生成，别从对话抄**
- **坑 7.7  config.toml 里 privileged/volumes 重复**
  - 现象：`FATAL: ... Key 'runners.docker.privileged' has already been defined`
  - 根因：sed 重复加 privileged（config 里已有）
  - 正确：用 heredoc 重写干净 config（privileged/volumes 各一份），别 sed 追加
  - 口诀：**config 用 heredoc 重写，别 sed 重复加**
- **坑 7.8  docker executor 要 socket 权限，或换 shell**
  - 现象：docker executor 无法 build（docker socket 权限）
  - 根因：docker executor 需要 privileged + volumes 挂 docker.sock；配置易错
  - 正确：**简单起见直接换 `--executor shell`**（宿主跑，宿主有 docker 就行）
  - 口诀：**嫌烦就用 shell executor，秒级绕开 socket 坑**
- **坑 7.9  git clone 失败 `Could not resolve host: gitlab-server`**
  - 现象：job 秒失败，`Could not resolve host: gitlab-server`
  - 根因：gitlab-runner 不认主机名 gitlab-server
  - 正确：`echo "172.25.254.105 gitlab-server" >> /etc/hosts`
  - 口诀：**gitlab-server 主机名要进 hosts**
- **坑 7.10  docker build 权限 denied /var/run/docker.sock**
  - 现象：`permission denied while trying to connect to the docker API`
  - 根因：gitlab-runner 用户不在 docker 组
  - 正确：`usermod -aG docker gitlab-runner` + `systemctl restart gitlab-runner`
  - 口诀：**shell executor 下，gitlab-runner 要加 docker 组**
- **坑 7.11  ⭐ docker build 拉基础镜像不走 daemon 代理**
  - 现象：`docker pull hello-world` 成功，但 `docker build` 拉 tomcat 失败
  - 根因：**BuildKit** 拉基础镜像不走 daemon 代理，直连 docker hub 被墙
  - 正确：daemon.json 配 `registry-mirrors`（国内加速器）→ BuildKit 走加速器；`docker pull tomcat:10.1.30` 先验证
  - 口诀：**build 拉镜像用 registry-mirrors，pull 用代理，两码事**
- **坑 7.12  push 到 Harbor http 被拒 / 401**
  - 现象：`push` 报 `:443 refused`（没信任）或 `unauthorized`（登录拒）
  - 根因：`insecure-registries` 没配（443 refused）；账号密码/权限不对（401）
  - 正确：daemon.json 加 `insecure-registries`；用 **admin/123456**（管理员有权限）
  - 口诀：**push Harbor：insecure-registries + 用 admin 账号**
- **坑 7.13  deploy 里 kubectl 连 localhost:8080**
  - 现象：deploy 阶段 `couldn't get current server API group list: Get "http://localhost:8080/api" ... connection refused`
  - 根因：**CI 用 `gitlab-runner` 用户跑**，kubeconfig 在 root 家目录，gitlab-runner 用户找不到 → kubectl 连 localhost:8080
  - 正确：把 kubeconfig 放 gitlab-runner 可读（`/home/gitlab-runner/.kube/config` + chown gitlab-runner），并在 yml `variables` 加 `KUBECONFIG: /home/gitlab-runner/.kube/config`
  - 口诀：**CI 里跑 kubectl，kubeconfig 要放 gitlab-runner 用户能读 + KUBECONFIG 指向它**
- **坑 7.14  外部访问 vs CI 内 deploy**
  - 现象：CI deploy 成功（内部好）但外部访问服务异常
  - 根因：deploy 换了镜像（k8s-demo 自带 demo），访问路径/内容变化；或 Pod 重建中；或网络/端口
  - 正确：deploy 后稍等 Pod 重建，核对访问 URL/端口；k8s-demo 镜像自带 webapps/demo，访问路径相应调整
  - 口诀：**deploy 成功 ≠ 外部立刻能访，核对 URL/端口/等待重建**

---

## 阶段8 监控（Prometheus + Grafana）

- **坑 8.1  ⭐ Prometheus 服务发现 `role:pod` 不抓 target**
  - 现象：`up` 查询空 / Targets 空，但 Status→Configuration 里 `scrape_configs` 已有 job
  - 根因：`kubernetes_sd_configs role:pod` 偶发不生效（权限/发现逻辑），难排查
  - 正确：**先用静态配置**`static_configs: - targets: ['exporterIP:9100']` 直接指向 exporter，立即跑通采集
  - 口诀：**服务发现失灵 → 先用 static_configs 静态 IP 快速跑通**
- **坑 8.2  Prometheus 服务发现需要 RBAC**
  - 现象：kubernetes_sd 抓不到 Pod
  - 根因：SA 没 list pods 权限（默认无权限）
  - 正确：给 prometheus ServiceAccount 配 ClusterRole(get/list/watch pods/nodes/services) + ClusterRoleBinding；用 `kubectl auth can-i list pods -n monitoring --as=system:serviceaccount:monitoring:prometheus` 验证（yes=通）
  - 口诀：**k8s 服务发现 = 必须先给 SA 配 RBAC 读权限**
- **坑 8.3  ⭐ Grafana 数据源：Explore/看板用 Default，URL 必须对**
  - 现象：有多个数据源，Explore 报 `An error occurred within the plugin` 或看板 No data
  - 根因：Explore/看板默认用 **Default 那个数据源**，若它 URL 不对(空/localhost)就报错；即使新建了 URL 对的，Explore 仍用旧 Default
  - 正确：**把 URL 对的设为 Default**（或删掉错的）；Explore 左上角数据源下拉手动选对的
  - 口诀：**Grafana 数据源：default 那个必须 URL 对，Explore 手动切对的**
- **坑 8.4  Grafana Explore Builder 模式不能输入查询**
  - 现象：Explore 里只能在 "Select metric" 下拉选 . 无法输入 `up`
  - 根因：Explore 默认 Builder(图形)模式
  - 正确：右上角切 **Code 模式**，查询框输入指标名(如 `up`)
  - 口诀：**Explore 查指标：切 Code 模式才能输文本**
- **坑 8.5  Grafana 访问 Prometheus 用集群内 ClusterIP DNS**
  - 现象：Grafana 连不上 Prometheus，插件报错
  - 根因：数据源 URL 填错地址
  - 正确：URL 用 `http://prometheus.monitoring:9090`；用 `kubectl exec -n monitoring deploy/grafana -- wget -qO- http://prometheus.monitoring:9090/-/healthy` 验证连通
  - 口诀：**Grafana 指 Prometheus：prometheus.monitoring:9090 + wget 验证**

---

## 附录：通用陷阱（别忽视）

- **拷命令别带 markdown 标记**：`@url:`、反引号 `` ` `` 很容易混进 token/url/命令里（本项目反复踩），复制后用纯文本，先 `grep`/`cat` 确认没污染。
- **地址访问：一律用 IP**，主机名（gitlab-server 等）要么加 hosts 要么别用。
- **docker 相关代理 = dockerd 层**：`docker pull` 走 daemon 代理；`docker build` 拉镜像走 registry-mirrors；两者都别指望终端 export 或 clash 全局。
- **凭证一律 login/insecure**：`docker login`（私有仓库）+ `insecure-registries`（http 仓库）是 push 的两个前提。

---

> **用法**：以后重做这套环境，按本手册"口诀"逐阶段走，凡是标 ⭐ 的坑都有对应排障思路，可直接当面试讲。配合《k8s项目执行文档》（详细版）使用更佳。
