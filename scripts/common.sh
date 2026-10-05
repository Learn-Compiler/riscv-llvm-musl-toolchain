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
BOOT="${BOOT:-$SRC/.bootstrap}"
STAMPS="${STAMPS:-$SRC/.build-stamps}"
SHIM="${SHIM:-$SRC/.musl-shim}"

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

# ─── Git 精确 commit 拉取器 ─────────────────────────────────────────────
fetch_commit() {   # $1=repo $2=sha $3=dest $4=检出后必须存在的哨兵文件
  local repo="$1" sha="$2" dest="$3" sentinel="$4" i got
  # 必须同时满足：工作区哨兵文件在 + git 目录在 + 目标提交在
  if [ -e "$dest/$sentinel" ] && [ -d "$dest/.git" ] \
     && git -C "$dest" cat-file -e "${sha}^{commit}" 2>/dev/null; then
    ok "$(basename "$dest") 已就绪（含 ${sha:0:12}），跳过"
    return
  fi
  echo "  拉取 $(basename "$dest") @ ${sha:0:12} ..."
  rm -rf "$dest"
  mkdir -p "$dest"
  git -C "$dest" init -q
  git -C "$dest" remote add origin "$repo"
  got=0
  for i in $(seq 1 10); do
    if git -C "$dest" fetch --depth 1 origin "$sha" >/dev/null 2>&1; then got=1; break; fi
    echo "    第 $i 次失败，10 秒后重试"; sleep 10
  done
  [ "$got" = 1 ] || die "拉取 $repo 失败（已重试 10 次）"
  git -C "$dest" checkout -q -f FETCH_HEAD
  [ -e "$dest/$sentinel" ] || die "$(basename "$dest") 检出后仍缺少 $sentinel"
  git -C "$dest" log -1 --format='  ✓ %h %ad %s' --date=short
}

# ─── 加载配置函数 ────────────────────────────────────────────────────────
init_config() {
  # 1. 载入全局默认配置
  if [ -f "$SRC/config/default.env" ]; then
    # shellcheck disable=SC1091
    source "$SRC/config/default.env"
  fi

  # 2. 载入用户本地个性化配置（若存在）
  if [ -f "$SRC/config/local.env" ]; then
    # shellcheck disable=SC1091
    source "$SRC/config/local.env"
  fi

  # 3. 载入目标平台配置
  TARGET="${TARGET:-riscv64-linux-musl}"
  local target_conf="$SRC/config/targets/${TARGET}.env"
  if [ -f "$target_conf" ]; then
    # shellcheck disable=SC1091
    source "$target_conf"
  else
    die "找不到目标平台配置文件: $target_conf"
  fi

  # 4. 载入已探测持久化的宿主编译器编译参数（若已探测）
  if [ -f "$BOOT/host_cxx_flags.env" ]; then
    # shellcheck disable=SC1091
    source "$BOOT/host_cxx_flags.env"
  fi
}
