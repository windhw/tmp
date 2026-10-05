#!/usr/bin/env bash
# OSWorld 2.1 本机自检（Docker provider）。
# 只做只读检查：不安装软件、不改配置；默认不拉任何镜像。
#
# 用法:
#   bash osworld_check.sh [目录]          目录 = 打算放 OSWorld-V2 和 VM 镜像的位置，默认当前目录
#   bash osworld_check.sh --deep [目录]   额外用 docker 实测容器里能否拿到 /dev/kvm（会拉一个约 4MB 的 alpine 镜像）
#
# 数字来源: OSWorld-V2 osworld-v2.1 的 benchmark_releases/osworld-v2.1.json
# 和 desktop_env/providers/docker/provider.py（每个环境 RAM_SIZE=4G, CPU_CORES=4）。

set -u

DEEP=0
if [ "${1:-}" = "--deep" ]; then DEEP=1; shift; fi
TARGET_DIR="${1:-$PWD}"

VM_RAM_GB=4           # 每个并行环境的 VM 内存
VM_CPUS=4             # 每个并行环境的 vCPU
PER_ENV_OVERHEAD_GB=1 # QEMU/容器自身开销（估算）
HOST_RESERVE_GB=4     # 宿主系统 + Python 评测进程（估算）
IMAGE_ZIP_GB=15       # osworld-v2-ubuntu-x86.qcow2.zip（14.9 GB）
IMAGE_QCOW2_GB=15     # 解压后的 qcow2（zip 为不压缩存储，同样 14.9 GB）
ASSETS_GB=5           # xlangai/osworld_v2_assets_gated
VENV_GB=2             # uv 虚拟环境（不含 --extra full）
PER_ENV_SCRATCH_GB=5  # 每个运行中环境的写入层 + 截图/录屏结果（估算）
HF_IMAGE_URL="https://huggingface.co/datasets/xlangai/v2-image/resolve/6e16459a2feb5a8f1ed65babcfe7a2a6205d049d/osworld-v2-ubuntu-x86.qcow2.zip"

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_TODO=$'\033[36m'; C_END=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_FAIL=""; C_TODO=""; C_END=""
fi
FAIL=0; WARN=0; TODO=0
ok()      { printf '  %s[OK]%s   %s\n' "$C_OK" "$C_END" "$*"; }
warn()    { printf '  %s[WARN]%s %s\n' "$C_WARN" "$C_END" "$*"; WARN=$((WARN+1)); }
fail()    { printf '  %s[FAIL]%s %s\n' "$C_FAIL" "$C_END" "$*"; FAIL=$((FAIL+1)); }
todo()    { printf '  %s[TODO]%s %s\n' "$C_TODO" "$C_END" "$*"; TODO=$((TODO+1)); }
info()    { printf '         %s\n' "$*"; }
section() { printf '\n== %s\n' "$*"; }
has()     { command -v "$1" >/dev/null 2>&1; }

summary() {
  section "结论"
  if [ "$FAIL" -gt 0 ]; then
    printf '  %s跑不起来（或只能极慢地跑）%s：先解决上面 %d 个 [FAIL]。\n' "$C_FAIL" "$C_END" "$FAIL"
  elif [ "$TODO" -gt 0 ]; then
    printf '  %s硬件条件满足%s，装好 %d 个 [TODO] 里的软件后可以跑。\n' "$C_OK" "$C_END" "$TODO"
  else
    printf '  %s可以跑%s。\n' "$C_OK" "$C_END"
  fi
  [ "$WARN" -gt 0 ] && printf '  另有 %d 个 [WARN] 是风险或限制，建议看一眼。\n' "$WARN"
  if [ -n "${REC_ENVS:-}" ] && [ "$FAIL" -eq 0 ]; then
    printf '  建议并行数: --num_envs %s\n' "$REC_ENVS"
  fi
  cat <<'EOF'

  本脚本查不到、但完整跑 108 题还需要的东西:
    - Hugging Face 账号，并在 xlangai/osworld_v2_tasks 和 xlangai/osworld_v2_assets_gated 页面同意 gated 访问
    - 被测模型的 API；外加打分模型 (OSWORLD_EVAL_MODEL_*) 和用户模拟器 (OSWORLD_USER_SIM_*) 的 API
    - 自建模拟网站 Task-Web/OSWorld-web@osworld-v2.1（官方参考规格 2核8G，可与评测同机）
    - GitLab 类任务需要自建 Task-Web/gitlab（官方建议单独一台 4核16G）
EOF
}

# ---------------------------------------------------------------------------
section "1. 系统与架构"
OS=$(uname -s); ARCH=$(uname -m)
case "$OS" in
  Linux)
    ok "Linux $(uname -r)"
    ;;
  Darwin)
    fail "macOS 没有 KVM，OSWorld 2.1 官方只提供 Docker(需 KVM) 和 AWS 两种镜像"
    [ "$ARCH" = "arm64" ] && fail "Apple 芯片无法以硬件虚拟化运行 x86 的 VM 镜像"
    info "建议: 换一台 Linux x86_64 机器（物理机或开了嵌套虚拟化的云主机），或用 AWS provider"
    summary; exit 1
    ;;
  *)
    fail "不支持的系统: $OS（Windows 请在 WSL2 里运行本脚本）"
    summary; exit 1
    ;;
esac

case "$ARCH" in
  x86_64|amd64) ok "架构 $ARCH" ;;
  *) fail "架构 $ARCH：OSWorld 2.1 只有 x86_64 镜像，ARM 机器只能软件模拟，基本不可用" ;;
esac

IS_WSL=0
if grep -qi microsoft /proc/version 2>/dev/null; then
  IS_WSL=1
  warn "检测到 WSL2：需要 Windows 11 且开启嵌套虚拟化才会有 /dev/kvm；若用 Docker Desktop，建议加 --deep 实测"
fi

VIRT=""
if has systemd-detect-virt; then
  VIRT=$(systemd-detect-virt 2>/dev/null || true)
elif grep -qw hypervisor /proc/cpuinfo 2>/dev/null; then
  VIRT="unknown-vm"
fi
case "$VIRT" in
  ""|none) ok "运行在物理机上" ;;
  docker|podman|lxc|lxc-libvirt|systemd-nspawn|container-other|wsl)
    [ "$IS_WSL" -eq 0 ] && warn "本机是容器环境 ($VIRT)，通常拿不到 /dev/kvm，也不方便再跑 Docker" ;;
  *)
    warn "本机本身是虚拟机 ($VIRT)：需要宿主开启嵌套虚拟化，下面 KVM 一项会体现出来"
    grep -qw hypervisor /proc/cpuinfo 2>/dev/null && info "依据: /proc/cpuinfo 带有 hypervisor 标志（由虚拟机管理程序设置）"
    HV=$(lscpu 2>/dev/null | awk -F: '/Hypervisor vendor/ {gsub(/^[ \t]+/, "", $2); print $2}')
    [ -n "$HV" ] && info "依据: lscpu 显示 Hypervisor vendor = $HV"
    DMI="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
    [ -n "${DMI// /}" ] && info "依据: 整机厂商/型号 (DMI) = $DMI"
    ;;
esac

# ---------------------------------------------------------------------------
section "2. KVM 硬件虚拟化"
VIRT_FLAGS=$(grep -cwE 'vmx|svm' /proc/cpuinfo 2>/dev/null)
VIRT_FLAGS=${VIRT_FLAGS:-0}
if [ "$VIRT_FLAGS" -gt 0 ]; then
  ok "CPU 支持硬件虚拟化 (vmx/svm)"
else
  fail "CPU 没有 vmx/svm 标志：BIOS 里没开 VT-x/AMD-V，或本机是没开嵌套虚拟化的虚拟机"
fi

if [ -e /dev/kvm ]; then
  ok "/dev/kvm 存在"
else
  fail "/dev/kvm 不存在：OSWorld 会退回纯软件模拟，非常慢，实际不可用"
  if [ "$VIRT_FLAGS" -gt 0 ]; then
    if grep -qw vmx /proc/cpuinfo; then info "可尝试: sudo modprobe kvm_intel"; else info "可尝试: sudo modprobe kvm_amd"; fi
  fi
fi

# ---------------------------------------------------------------------------
section "3. CPU 与内存"
CORES=$(nproc 2>/dev/null || echo 1)
MEM_GB=$(awk '/^MemTotal:/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
AVAIL_GB=$(awk '/^MemAvailable:/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
info "CPU 逻辑核数: $CORES；内存: 共 ${MEM_GB} GB，当前可用 ${AVAIL_GB} GB"

PER_ENV_MEM=$((VM_RAM_GB + PER_ENV_OVERHEAD_GB))
BY_MEM=$(( (MEM_GB - HOST_RESERVE_GB) / PER_ENV_MEM ))
[ "$BY_MEM" -lt 0 ] && BY_MEM=0
BY_CPU=$(( CORES / VM_CPUS ))
REC_ENVS=$BY_MEM
[ "$BY_CPU" -lt "$REC_ENVS" ] && REC_ENVS=$BY_CPU

if [ "$BY_MEM" -lt 1 ]; then
  fail "内存不足：一个环境就要约 $((PER_ENV_MEM + HOST_RESERVE_GB)) GB（VM ${VM_RAM_GB}G + 开销 + 宿主）"
  REC_ENVS=""
else
  ok "按内存最多 $BY_MEM 个并行环境（每个约 ${PER_ENV_MEM} GB，宿主预留 ${HOST_RESERVE_GB} GB）"
fi
if [ "$BY_CPU" -lt 1 ]; then
  warn "CPU 少于 $VM_CPUS 核：每个 VM 默认 $VM_CPUS 核，会超卖，步骤之间会明显变慢"
  [ -n "$REC_ENVS" ] && REC_ENVS=1
else
  ok "按 CPU 最多 $BY_CPU 个并行环境（每个 $VM_CPUS 核，不超卖）"
fi
if [ -n "$REC_ENVS" ] && [ "$MEM_GB" -lt $((HOST_RESERVE_GB + PER_ENV_MEM + 8)) ]; then
  warn "内存不够在本机同时跑模拟网站（约 8 GB），网站栈建议放另一台机器"
fi

# ---------------------------------------------------------------------------
section "4. 磁盘"
CHECK_DIR="$TARGET_DIR"
while [ ! -d "$CHECK_DIR" ]; do CHECK_DIR=$(dirname "$CHECK_DIR"); done
FREE_GB=$(df -Pk "$CHECK_DIR" | awk 'NR==2 {printf "%d", $4/1024/1024}')
ENVS_FOR_DISK=${REC_ENVS:-1}
[ "$ENVS_FOR_DISK" -lt 1 ] && ENVS_FOR_DISK=1
NEED_GB=$((IMAGE_ZIP_GB + IMAGE_QCOW2_GB + ASSETS_GB + VENV_GB + PER_ENV_SCRATCH_GB * ENVS_FOR_DISK))
NEED_MIN_GB=$((NEED_GB - IMAGE_ZIP_GB))
info "$CHECK_DIR 所在分区可用 ${FREE_GB} GB"
info "需要约 ${NEED_GB} GB = 镜像zip ${IMAGE_ZIP_GB} + qcow2 ${IMAGE_QCOW2_GB} + 资产 ${ASSETS_GB} + 依赖 ${VENV_GB} + ${ENVS_FOR_DISK}个环境×${PER_ENV_SCRATCH_GB}"
if [ "$FREE_GB" -ge "$NEED_GB" ]; then
  ok "磁盘空间够"
elif [ "$FREE_GB" -ge "$NEED_MIN_GB" ]; then
  warn "空间偏紧：解压完后要手动删掉 docker_vm_data/*.zip（省 ${IMAGE_ZIP_GB} GB），否则解压时会不够"
else
  fail "磁盘不足：至少需要约 ${NEED_MIN_GB} GB"
fi

# ---------------------------------------------------------------------------
section "5. 软件"
DOCKER_OK=0
if ! has docker; then
  todo "未安装 Docker Engine（https://docs.docker.com/engine/install/）"
else
  DOCKER_ERR=$(docker info 2>&1 >/dev/null)
  if [ $? -eq 0 ]; then
    DOCKER_OK=1
    ok "Docker 可用 ($(docker version -f '{{.Server.Version}}' 2>/dev/null))"
    DOCKER_OS=$(docker info -f '{{.OperatingSystem}}' 2>/dev/null)
    case "$DOCKER_OS" in
      *"Docker Desktop"*) warn "Docker Desktop 的容器跑在它自己的 VM 里，/dev/kvm 未必能透传；建议换 Docker Engine 或用 --deep 实测" ;;
    esac
    ROOT_DIR=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null)
    if [ -n "$ROOT_DIR" ] && [ -d "$ROOT_DIR" ]; then
      ROOT_FREE=$(df -Pk "$ROOT_DIR" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}')
      [ -n "$ROOT_FREE" ] && info "Docker 数据目录 $ROOT_DIR 可用 ${ROOT_FREE} GB（容器运行时写入在这里）"
    fi
  elif printf '%s' "$DOCKER_ERR" | grep -qi "permission denied"; then
    todo "当前用户无权访问 Docker：sudo usermod -aG docker \$USER，然后重新登录"
  else
    todo "Docker 守护进程没在运行：sudo systemctl start docker"
  fi
fi
if has docker && docker compose version >/dev/null 2>&1; then
  ok "docker compose 插件可用（自建模拟网站/GitLab 用）"
else
  todo "缺少 docker compose 插件（只在自建模拟网站/GitLab 时需要）"
fi

if has uv; then
  ok "uv $(uv --version 2>/dev/null | awk '{print $2}')（会自动准备 Python 3.12）"
else
  PYV=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "无")
  todo "未安装 uv（本机 python3: $PYV；OSWorld 2.1 要 Python >= 3.12）: curl -LsSf https://astral.sh/uv/install.sh | sh"
fi
for t in git curl; do
  if has "$t"; then ok "$t 已安装"; else todo "未安装 $t"; fi
done

# ---------------------------------------------------------------------------
section "6. 网络（会走当前环境的 HTTP(S)_PROXY）"
probe() { curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$1" 2>/dev/null; }
if ! has curl; then
  warn "没有 curl，跳过网络检查"
else
  HF=$(probe https://huggingface.co/api/datasets/xlangai/v2-image)
  MIRROR=$(probe https://hf-mirror.com)
  if [ "$HF" != "000" ]; then
    ok "huggingface.co 可访问"
  elif [ "$MIRROR" != "000" ]; then
    warn "huggingface.co 不通，但 hf-mirror.com 可以：export HF_ENDPOINT=https://hf-mirror.com（gated 数据集需带 HF token）"
  else
    fail "huggingface.co 和 hf-mirror.com 都不通：VM 镜像、任务和资产都下载不了"
  fi
  if [ "$(probe https://registry-1.docker.io/v2/)" != "000" ]; then
    ok "Docker Hub 可访问（拉 happysixd/osworld-docker，约 84 MB）"
  else
    warn "Docker Hub 不通：需要给 Docker 配镜像加速或代理"
  fi
  if [ "$(probe https://github.com)" != "000" ]; then ok "github.com 可访问"; else warn "github.com 不通：拉不了 OSWorld-V2 / OSWorld-web 代码"; fi
  for api in api.anthropic.com api.openai.com; do
    if [ "$(probe https://$api)" != "000" ]; then ok "$api 可访问"; else warn "$api 不通（如果被测/打分模型用它，需要代理）"; fi
  done

  # 测一下下载 VM 镜像的速度（下 20 MB 就停）
  SPEED_URL="$HF_IMAGE_URL"
  [ "$HF" = "000" ] && [ "$MIRROR" != "000" ] && SPEED_URL=${HF_IMAGE_URL/huggingface.co/hf-mirror.com}
  if [ "$HF" != "000" ] || [ "$MIRROR" != "000" ]; then
    BPS=$(curl -sL -r 0-20971519 -o /dev/null -w '%{speed_download}' --max-time 30 "$SPEED_URL" 2>/dev/null)
    BPS=${BPS%%.*}
    if [ -n "$BPS" ] && [ "$BPS" -gt 0 ] 2>/dev/null; then
      MBPS=$((BPS / 1024 / 1024))
      ETA_MIN=$(( IMAGE_ZIP_GB * 1024 * 1024 * 1024 / BPS / 60 ))
      info "镜像下载速度约 ${MBPS} MB/s，下载 ${IMAGE_ZIP_GB} GB 镜像约需 ${ETA_MIN} 分钟（中断可续传）"
    fi
  fi
fi

# ---------------------------------------------------------------------------
section "7. 端口"
if has ss; then
  LISTEN=$(ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | sed 's/.*://' | sort -u)
  for p in 80 443; do
    if printf '%s\n' "$LISTEN" | grep -qx "$p"; then
      warn "端口 $p 已被占用：在本机自建模拟网站（Caddy 要占 80/443）会冲突"
    fi
  done
  BUSY=""
  for p in 5000 8006 9222 8080; do
    printf '%s\n' "$LISTEN" | grep -qx "$p" && BUSY="$BUSY $p"
  done
  if [ -n "$BUSY" ]; then
    info "端口${BUSY} 已被占用，不影响：OSWorld 会自动顺延到下一个空闲端口"
  else
    ok "VM 默认端口 5000/8006/9222/8080 空闲"
  fi
else
  info "没有 ss 命令，跳过端口检查"
fi

# ---------------------------------------------------------------------------
if [ "$DEEP" -eq 1 ]; then
  section "8. 实测：容器内能否使用 /dev/kvm"
  if [ "$DOCKER_OK" -eq 1 ] && [ -e /dev/kvm ]; then
    if docker run --rm --device /dev/kvm alpine:3 sh -c 'test -c /dev/kvm && test -r /dev/kvm && test -w /dev/kvm' >/dev/null 2>&1; then
      ok "容器内可以读写 /dev/kvm"
    else
      fail "容器内拿不到 /dev/kvm（Docker Desktop/rootless Docker 常见），VM 会退回软件模拟"
    fi
  else
    info "Docker 不可用或 /dev/kvm 不存在，跳过"
  fi
fi

summary
[ "$FAIL" -eq 0 ]
