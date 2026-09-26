#!/bin/bash
# ============================================================
# 母盘环境体检脚本 —— 验证 K8s 实验母盘是否配置到位、可安全克隆
# 用法：在【母盘虚拟机】内以 root 运行：  bash 母盘体检.sh
# 作者：Hermes 助教 (黄茂烊·运维求职)
# ============================================================
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; NC='\033[0m'
PASS=0; WARN=0; FAIL=0
ok()   { echo -e "${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; WARN=$((WARN+1)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); }

echo "==================== 母盘环境体检 ===================="
echo "系统: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
echo "内核: $(uname -r)"
echo "======================================================"

# ---------- [1] 防火墙 ----------
echo -e "\n[1] 防火墙 firewalld"
isact=$(systemctl is-active firewalld 2>/dev/null)
enab=$(systemctl is-enabled firewalld 2>/dev/null)
load=$(systemctl show -p LoadState firewalld 2>/dev/null | cut -d= -f2)
if [ "$load" = "masked" ]; then
  ok "firewalld 已屏蔽(masked)，无法被启动"
elif [ "$isact" != "active" ] && { [ "$enab" = "disabled" ] || [ "$enab" = "masked" ]; }; then
  ok "firewalld 已禁用 (active=$isact, enabled=$enab)"
else
  fail "firewalld 未彻底禁用 (active=$isact, enabled=$enab)"
  echo "    修复: systemctl disable --now firewalld && systemctl mask firewalld && reboot"
fi

# ---------- [2] SELinux ----------
echo -e "\n[2] SELinux"
selcfg=$(grep -E '^\s*SELINUX=' /etc/selinux/config 2>/dev/null | head -1 | cut -d= -f2)
enforce=$(getenforce 2>/dev/null)
if [ "$enforce" = "Disabled" ] || [ "$selcfg" = "disabled" ]; then
  ok "SELinux 已禁用 (getenforce=$enforce, config=$selcfg)"
else
  fail "SELinux 未禁用 (getenforce=$enforce, config=$selcfg)"
  echo "    修复: 编辑 /etc/selinux/config 设 SELINUX=disabled，然后 reboot"
fi

# ---------- [3] 网卡命名 ----------
echo -e "\n[3] 网卡命名 (传统 eth*)"
if ip link show eth0 >/dev/null 2>&1; then
  ok "传统命名生效，存在 eth0"
else
  fail "未检测到 eth0。可能仍是 ens160 等现代命名"
  echo "    修复: 引导参数加 net.ifnames=0 后 reboot"
fi

# ---------- [4] 本地仓库 ----------
echo -e "\n[4] 本地仓库 (RHEL 光盘源)"
if mountpoint -q /rhel 2>/dev/null; then
  ok "/rhel 已挂载"
else
  fail "/rhel 未挂载。修复: mount /dev/cdrom /rhel"
fi
if grep -rlE '^\s*\[AppStream\]' /etc/yum.repos.d/ 2>/dev/null | grep -q .; then
  ok "本地仓库 .repo 文件存在 (含 [AppStream])"
else
  warn "未找到含 [AppStream]  的本地仓库文件 (应为 file:///rhel/ 指向光盘)"
fi
if dnf repolist >/dev/null 2>&1; then
  ok "dnf repolist 正常"
else
  fail "dnf 仓库异常，检查 rhel.repo / 挂载"
fi
if [ -x /etc/rc.d/rc.local ] && grep -q 'mount /dev/cdrom' /etc/rc.d/rc.local 2>/dev/null; then
  ok "rc.local 已配置开机自动挂载 /rhel"
else
  warn "rc.local 未配置开机自动挂载 (重启后需手动 mount /dev/cdrom /rhel)"
fi

# ---------- [5] vmset.sh ----------
echo -e "\n[5] vmset.sh 网络配置脚本"
if [ -x /bin/vmset.sh ]; then
  ok "/bin/vmset.sh 存在且可执行"
else
  warn "/bin/vmset.sh 缺失或不可执行 (克隆后要用它设 IP/主机名)"
fi

# ---------- [6] SSH 免密 ----------
echo -e "\n[6] SSH 免密登录"
[ -f /root/.ssh/id_rsa ] && ok "root 密钥已生成 (~/.ssh/id_rsa)" || warn "root 未生成密钥 (ssh-keygen)"
[ -s /root/.ssh/authorized_keys ] && ok "authorized_keys 已配置" || warn "authorized_keys 为空 (ssh-copy-id 到本机)"
grep -qE '^\s*StrictHostKeyChecking\s+no' /etc/ssh/ssh_config 2>/dev/null && ok "ssh_config 已关闭严格主机检查" || warn "ssh_config 未配 StrictHostKeyChecking no"
[ -d /etc/skel/.ssh ] && ok "/etc/skel/.ssh 已复制 (新建用户自动免密)" || warn "/etc/skel/.ssh 缺失 (新用户不会自动免密)"
if ssh -o BatchMode=yes -o ConnectTimeout=5 root@localhost true 2>/dev/null; then
  ok "root@localhost 免密登录成功"
else
  warn "免密登录测试未通过 (确认 sshd 已启动且 authorized_keys 含公钥)"
fi

# ---------- [7] vim 配置 (建议补) ----------
echo -e "\n[7] vim 简化配置 (.vimrc)"
[ -f /root/.vimrc ] && ok ".vimrc 已配置" || warn "未配置 .vimrc —— 建议母盘就配好(防 YAML 缩进/空格报错)"

# ---------- [8] 网络仓库 (建议补) ----------
echo -e "\n[8] 网络仓库 (docker / k8s 源)"
grep -rlE 'docker-ce' /etc/yum.repos.d/ 2>/dev/null | grep -q . && ok "docker 源已配置" || warn "未配置 docker 源 —— 装 Docker 前必须配 aliyun docker-ce 源"
grep -rlE 'kubernetes' /etc/yum.repos.d/ 2>/dev/null | grep -q . && ok "k8s 源已配置" || warn "未配置 k8s 源 —— 装 kubeadm/kubelet/kubectl 前必须配 aliyun kubernetes 源"

# ---------- 汇总 ----------
echo -e "\n======================================================"
echo -e "体检结果: ${GREEN}${PASS} 通过${NC}  ${YELLOW}${WARN} 提示${NC}  ${RED}${FAIL} 失败${NC}"
echo "说明: WARN = 可后补(不阻塞克隆)；FAIL = 必须先修复才能克隆使用"
echo "======================================================"
[ "$FAIL" -eq 0 ] && echo "✅ 母盘基本干净可克隆（建议顺手补掉 WARN 项）" || echo "❌ 存在 FAIL 项，请先修复再继续"
