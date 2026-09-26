#!/bin/bash
# =============================================================
# node_init.sh —— K8s worker 节点一键初始化脚本
# 适用对象：k8s-node1 / k8s-node2（从 RHEL9.6 母盘完整克隆而来）
#
# 必须在【克隆后、join 之前】完成以下前置：
#   1. 已用 vmset.sh 设好 IP 和主机名，例如：
#        vmset.sh eth0 172.25.254.102 k8s-node1
#   2. 能 ping 通 master： ping -c1 172.25.254.101
#   3. master 在线（本脚本要从 master 拷贝 cri-dockerd 和各项集群配置）
#   4. 本节点能免密 ssh 到 master： ssh root@172.25.254.101 'true'
#      （若没配，先执行： ssh-keygen -t rsa && ssh-copy-id root@172.25.254.101）
#
# 用法： bash node_init.sh
# 注意：本脚本【不含】kubeadm join，join 需在脚本跑完后单独执行。
# =============================================================

# ---- 关键常量 ----
MASTER_IP=172.25.254.101
MASTER="root@${MASTER_IP}"

# 全部节点（写入每台 /etc/hosts，幂等）
cat > /tmp/k8s_hosts <<'EOF'
172.25.254.101 k8s-master
172.25.254.102 k8s-node1
172.25.254.103 k8s-node2
172.25.254.105 gitlab
EOF

echo "=================================================================="
echo " 节点初始化开始：$(hostname)  IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet )\S+')"
echo "=================================================================="

# ---------- [1/10] 与 master 连通性检查 ----------
echo ""
echo "== [1/10] 检查与 master 连通性 =="
ping -c1 -W2 ${MASTER_IP} >/dev/null 2>&1 \
  && echo "  ✓ ping ${MASTER_IP} 通" \
  || { echo "  ✗ ping 不通，先检查网络"; exit 1; }
ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${MASTER} 'true' 2>/dev/null \
  && echo "  ✓ 已免密 ssh 到 master" \
  || { echo "  ✗ 未配置 node→master 免密，请先执行：ssh ${MASTER}（输一次密码）"; exit 1; }

# ---------- [2/10] 从 master 拷贝 cri-dockerd 及集群配置 ----------
echo ""
echo "== [2/10] 从 master 拷贝 cri-dockerd 与配置 =="
mkdir -p /usr/bin /etc/systemd/system /etc/yum.repos.d /etc/docker /etc/sysconfig
scp -o StrictHostKeyChecking=no ${MASTER}:/usr/bin/cri-dockerd /usr/bin/ 2>/dev/null \
  || { echo "  ✗ cri-dockerd 拷贝失败"; exit 1; }
scp -o StrictHostKeyChecking=no ${MASTER}:/etc/systemd/system/cri-docker.service /etc/systemd/system/ 2>/dev/null
scp -o StrictHostKeyChecking=no ${MASTER}:/etc/systemd/system/cri-docker.socket /etc/systemd/system/ 2>/dev/null || true
scp -o StrictHostKeyChecking=no ${MASTER}:/etc/yum.repos.d/docker.repo /etc/yum.repos.d/ 2>/dev/null
scp -o StrictHostKeyChecking=no ${MASTER}:/etc/yum.repos.d/k8s.repo /etc/yum.repos.d/ 2>/dev/null
scp -o StrictHostKeyChecking=no ${MASTER}:/etc/docker/daemon.json /etc/docker/ 2>/dev/null
scp -o StrictHostKeyChecking=no ${MASTER}:/etc/sysconfig/kubelet /etc/sysconfig/ 2>/dev/null || true
chmod +x /usr/bin/cri-dockerd
echo "  ✓ 配置已从 master 拷贝完成"

# ---------- [3/10] 关闭 swap ----------
echo ""
echo "== [3/10] 关闭 swap =="
swapoff -a
sed -i '/swap/s/^/#/' /etc/fstab
echo "  ✓ swap 已关闭，并已注释 fstab（重启不启用）"

# ---------- [4/10] 确保防火墙 & SELinux 关闭（母盘已禁则跳过）----------
echo ""
echo "== [4/10] 确保防火墙 & SELinux 关闭 =="
systemctl disable --now firewalld >/dev/null 2>&1 || true
getenforce | grep -qi disabled || { setenforce 0; sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config; }
echo "  ✓ firewalld 停止，SELinux=$(getenforce)"

# ---------- [5/10] 安装并启动 Docker ----------
echo ""
echo "== [5/10] 安装 Docker（走 master 拷来的 docker.repo）=="
dnf install -y docker-ce >/dev/null 2>&1 || { echo "  ✗ docker-ce 安装失败，检查 docker.repo"; exit 1; }
systemctl enable --now docker
echo "  ✓ Docker 已安装并启动：$(docker --version)"
docker info 2>/dev/null | grep -i "Cgroup Driver" && echo "  ✓ cgroup 驱动就绪"

# ---------- [6/10] 启动 cri-dockerd ----------
echo ""
echo "== [6/10] 启动 cri-dockerd =="
systemctl daemon-reload
systemctl enable --now cri-docker
echo "  ✓ cri-dockerd 已启动"

# ---------- [7/10] 安装 k8s 三件套 v1.31.0 ----------
echo ""
echo "== [7/10] 安装 kubeadm/kubelet/kubectl v1.31.0 =="
dnf install -y kubeadm-1.31.0 kubelet-1.31.0 kubectl-1.31.0 >/dev/null 2>&1 \
  || { echo "  ✗ 三件套安装失败，检查 k8s.repo"; exit 1; }
systemctl enable kubelet
echo "  ✓ 三件套安装完成：$(kubelet --version)"

# ---------- [8/10] 内核网络参数（br_netfilter + 转发 + 桥接过安检）----------
echo ""
echo "== [8/10] 配置内核网络参数 =="
modprobe br_netfilter
lsmod | grep -q br_netfilter && echo "  ✓ br_netfilter 模块已加载" || echo "  ✗ 模块加载失败"
cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
echo "br_netfilter" > /etc/modules-load.d/k8s.conf
sysctl --system >/dev/null 2>&1
sysctl -n net.bridge.bridge-nf-call-iptables | grep -q 1 && echo "  ✓ 内核参数已生效"

# ---------- [9/10] 时间同步 + hosts 记录 ----------
echo ""
echo "== [9/10] 时间同步 & hosts 记录 =="
dnf install -y chrony >/dev/null 2>&1
systemctl enable --now chronyd >/dev/null 2>&1
echo "  ✓ chrony 时间同步已开启"
while read -r ip hm; do
  grep -q "${ip} ${hm}" /etc/hosts || echo "${ip} ${hm}" >> /etc/hosts
done < /tmp/k8s_hosts
echo "  ✓ /etc/hosts 已包含全部节点"

# ---------- [10/10] 汇总验证 ----------
echo ""
echo "== [10/10] 汇总验证 =="
echo "  Docker 版本   ：$(docker --version)"
echo "  kubeadm 版本  ：$(kubeadm version -o short 2>/dev/null)"
echo "  cgroup 驱动   ：$(docker info 2>/dev/null | grep -i 'Cgroup Driver' | awk '{print $3}')"
echo "  swap 条目数   ：$(swapon --show | wc -l)（应为 0）"
echo "  ip_forward    ：$(sysctl -n net.ipv4.ip_forward)"
echo "  bridge-nf-call-iptables：$(sysctl -n net.bridge.bridge-nf-call-iptables)"
echo ""
echo "============================================================"
echo "  节点初始化完成！下一步："
echo "  在 master 上执行（若 join 命令丢失，用它重新生成）："
echo "      kubeadm token create --print-join-command"
echo "  把输出命令拿到本节点执行： kubeadm join ..."
echo "============================================================"
