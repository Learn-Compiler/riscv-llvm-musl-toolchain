#!/usr/bin/env bash
# ==============================================================================
# scripts/common.sh - 通用基础设施函数与环境变量初始化
# ==============================================================================
set -euo pipefail

# ─── 路径定位 ────────────────────────────────────────────────────────────
# 以 common.sh 所在目录计算根目录 SRC
if [ -z "${SRC:-}" ]; then
  SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

INSTALL="${INSTALL:-$SRC/install-clang-musl}"
SYSROOT="${SYSROOT:-$INSTALL/sysroot}"
BUILD="${BUILD:-$SRC/build-llvm-musl}"
BUILD_RUNTIMES="${BUILD_RUNTIMES:-$SRC/build-runtimes}"
BOOT="${BOOT:-$SRC/.bootstrap}"
STAMPS="${STAMPS:-$SRC/.build-stamps}"
LLVM_DIR="${LLVM_DIR:-$SRC/third_party/llvm}"
MUSL_DIR="${MUSL_DIR:-$SRC/third_party/musl}"
LINUX_HEADERS_DIR="${LINUX_HEADERS_DIR:-$SRC/third_party/linux-headers}"

get_linux_headers_include_dir() {
  if [ -d "${LINUX_HEADERS_DIR:-}/include" ]; then
    echo "$LINUX_HEADERS_DIR/include"
  elif [ -d "${LINUX_HEADERS_DIR:-}/riscv/include" ]; then
    echo "$LINUX_HEADERS_DIR/riscv/include"
  elif [ -d "$SRC/linux-headers/include" ]; then
    echo "$SRC/linux-headers/include"
  else
    echo "${LINUX_HEADERS_DIR:-$SRC/third_party/linux-headers}/include"
  fi
}

# 将自举引导工具优先加入 PATH 与动态库检索路径
export PATH="$BOOT/bin:${PATH}"
export LD_LIBRARY_PATH="$BOOT/lib:${LD_LIBRARY_PATH:-}"

# ─── 终端颜色与输出 ──────────────────────────────────────────────────────
c_ok=$'\033[1;32m'; c_er=$'\033[1;31m'; c_hd=$'\033[1;36m'; c_warn=$'\033[1;33m'; c_off=$'\033[0m'
log()  { printf '\n%s==> %s%s\n' "$c_hd" "$*" "$c_off"; }
ok()   { printf '%s  ✓ %s%s\n' "$c_ok" "$*" "$c_off"; }
warn() { printf '%s  ! %s%s\n' "$c_warn" "$*" "$c_off"; }
die()  { printf '\n%s!! %s%s\n' "$c_er" "$*" "$c_off" >&2; exit 1; }

# ─── 幂等时间戳状态机 ────────────────────────────────────────────────────
is_done() { [ -f "$STAMPS/$1" ]; }
mark()    { mkdir -p "$STAMPS"; date '+%F %T' > "$STAMPS/$1"; }
unmark()  { rm -f "$STAMPS/$1"; }

# ─── 断点续传下载器 ──────────────────────────────────────────────────────
# GitHub release 资源带 accept-ranges: bytes，可用 -C - 续传。
fetch_file() {   # $1=url $2=dest
  local url="$1" dest="$2" want size i curlok
  want=$(curl -sIL --max-time 60 "$url" | tr -d '\r' \
         | awk 'tolower($1)=="content-length:"{v=$2} END{print v}')
  if [ -n "$want" ] && [ "$want" != 0 ]; then printf '  目标大小 %s 字节\n' "$want"; fi
  for i in $(seq 1 60); do
    size=$(stat -c%s "$dest" 2>/dev/null || echo 0)
    if [ -n "$want" ] && [ "$size" = "$want" ]; then return 0; fi
    curlok=0
    curl -fL --retry 2 --retry-delay 2 --retry-all-errors \
         -C - -o "$dest" "$url" && curlok=1
    size=$(stat -c%s "$dest" 2>/dev/null || echo 0)
    if [ -n "$want" ]; then
      [ "$size" = "$want" ] && return 0
    else
      [ "$curlok" = 1 ] && return 0
    fi
    printf '    中断于 %s/%s 字节，3 秒后断点续传（第 %d 次）\n' "$size" "${want:-?}" "$i"
    sleep 3
  done
  return 1
}


# ─── 自适应并发任务数探测 (兼顾 CPU 核心与物理内存，防 OOM) ─────────────
detect_optimal_jobs() {
  local ncpu mem_kb mem_gb max_jobs_by_mem jobs
  ncpu=$(nproc 2>/dev/null || echo 4)
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  mem_gb=$(( mem_kb / 1024 / 1024 ))

  if [ "$mem_gb" -gt 0 ]; then
    # 每个 C++ 复杂编译/链接任务约预留 2GB 物理内存，防止高并发导致 OOM 崩溃
    max_jobs_by_mem=$(( mem_gb / 2 ))
    [ "$max_jobs_by_mem" -lt 1 ] && max_jobs_by_mem=1
    if [ "$ncpu" -gt "$max_jobs_by_mem" ]; then
      jobs="$max_jobs_by_mem"
    else
      jobs="$ncpu"
    fi
  else
    jobs="$ncpu"
  fi
  [ "$jobs" -lt 1 ] && jobs=1
  echo "$jobs"
}

# ─── 加载配置函数 ────────────────────────────────────────────────────────
init_config() {
  # 1. 载入全局默认配置
  if [ -f "$SRC/config/default.env" ]; then
    # shellcheck disable=SC1091
    source "$SRC/config/default.env"
  fi

  # 2. 载入版本锁定配置（若存在）
  if [ -f "$SRC/config/versions.lock" ]; then
    # shellcheck disable=SC1091
    source "$SRC/config/versions.lock"
  fi

  # 3. 载入用户本地个性化配置（若存在，可覆盖锁定版本）
  if [ -f "$SRC/config/local.env" ]; then
    # shellcheck disable=SC1091
    source "$SRC/config/local.env"
  fi

  # 4. 载入目标平台配置
  TARGET="${TARGET:-riscv64-linux-musl}"
  local target_conf="$SRC/config/targets/${TARGET}.env"
  if [ -f "$target_conf" ]; then
    # shellcheck disable=SC1091
    source "$target_conf"
  else
    die "找不到目标平台配置文件: $target_conf"
  fi

  # 5. 载入已探测持久化的宿主编译器编译参数（若已探测）
  if [ -f "$BOOT/host_cxx_flags.env" ]; then
    # shellcheck disable=SC1091
    source "$BOOT/host_cxx_flags.env"
  fi

  # 6. 并行构建线程数探测与自适应计算
  if [ "${JOBS:-auto}" = "auto" ] || [ -z "${JOBS:-}" ]; then
    JOBS="$(detect_optimal_jobs)"
  fi
}
