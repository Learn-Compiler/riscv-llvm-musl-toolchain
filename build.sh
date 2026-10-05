#!/usr/bin/env bash
# ==============================================================================
# build.sh - riscv-llvm-musl 工具链主构建入口与编排器
# ==============================================================================
# 特点：
#   * 最终工具链里没有 GCC，也没有 libgcc —— 运行时全部来自 compiler-rt
#   * 宿主引导工具也全部免 root（官方自包含二进制 + dpkg -x 解包）
#   * 幂等：可重复执行，已完成的步骤自动跳过
#   * 模块化架构：配置解耦、单步调试支持、方便芯片自研与二次开发拓展
# ==============================================================================
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SRC/scripts/common.sh"

show_help() {
  cat <<'EOF'
用法:
  ./build.sh [选项]

常用构建选项:
  ./build.sh                     完整构建流程（自举 -> 源码 -> builtins -> musl -> llvm -> prune -> verify）
  ./build.sh --fetch             仅准备自举工具并拉取源码
  ./build.sh --package           构建完成后打包生成 .tar.zst 离线发布包
  ./build.sh --rebuild-llvm      重新编译 LLVM 模块与运行库（二次开发常用）
  ./build.sh --clean             清理编译临时目录与时间戳（保留 .bootstrap）
  ./build.sh --clean-all         清理所有内容（包括 .bootstrap 引导工具）

高级调试与拓展选项:
  ./build.sh --step <步骤名>     单独执行某一特定步骤
  ./build.sh --from <步骤名>     从指定步骤开始向下连续执行
  ./build.sh --target <目标名>   指定目标平台配置 (对应 config/targets/<目标名>.env)
  JOBS=8 ./build.sh              指定并行构建核心数 (默认 6)

可选步骤名列表:
  bootstrap  - 准备免 root 引导工具并探测宿主 C++
  fetch      - 拉取源码或挂载本地自研源码
  builtins   - 安装 musl 基础头文件并编译 compiler-rt builtins
  musl       - 编译 Musl libc 并安装至 Sysroot
  llvm       - 编译 LLVM/Clang 及全部运行时 (compiler-rt/libc++/libunwind)
  prune      - 精简无用跨平台工具、剥离符号、生成三元组链接与 .cfg
  verify     - 工具链运行库检查与 C/C++ 冒烟测试
  package    - 离线打包生成 .tar.zst 与 SHA256 校验和
EOF
  exit 0
}

# ─── 参数解析 ────────────────────────────────────────────────────────────
ONLY_FETCH=0
DO_PACKAGE=0
REBUILD_LLVM=0
SELECTED_STEP=""
START_FROM=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      show_help
      ;;
    --fetch)
      ONLY_FETCH=1
      shift
      ;;
    --package)
      DO_PACKAGE=1
      shift
      ;;
    --rebuild-llvm)
      REBUILD_LLVM=1
      shift
      ;;
    --step)
      [ -n "${2:-}" ] || die "--step 需要指定步骤名称"
      SELECTED_STEP="$2"
      shift 2
      ;;
    --from)
      [ -n "${2:-}" ] || die "--from 需要指定起始步骤名称"
      START_FROM="$2"
      shift 2
      ;;
    --target)
      [ -n "${2:-}" ] || die "--target 需要指定目标名称"
      TARGET="$2"
      shift 2
      ;;
    --clean)
      log "清理构建缓存与时间戳 ..."
      rm -rf "$STAMPS" "$BUILD" "$SRC/build-compiler-rt" "$INSTALL" "$SHIM"
      ok "清理完成"
      exit 0
      ;;
    --clean-all)
      log "完全清理构建缓存与引导环境 ..."
      rm -rf "$STAMPS" "$BUILD" "$SRC/build-compiler-rt" "$INSTALL" "$SHIM" "$BOOT"
      ok "全部清理完成"
      exit 0
      ;;
    *)
      die "未知参数: $1 (运行 ./build.sh --help 查看说明)"
      ;;
  esac
done

# 初始化基础配置与目标平台
init_config

# ─── 前置检查 ────────────────────────────────────────────────────────────
[ -d "$SRC/linux-headers/include" ] || die "缺少 $SRC/linux-headers/include"
command -v curl >/dev/null || die "缺少 curl"
command -v tar  >/dev/null || die "缺少 tar"

printf '%s%s 无 GCC 工具链构建%s\n' "$c_hd" "$TARGET_TRIPLE" "$c_off"
printf '  SRC     = %s\n  INSTALL = %s\n  JOBS    = %s\n' "$SRC" "$INSTALL" "$JOBS"

# 引入所有步骤模块
# shellcheck disable=SC1091
source "$SRC/scripts/01_bootstrap.sh"
# shellcheck disable=SC1091
source "$SRC/scripts/02_fetch.sh"
# shellcheck disable=SC1091
source "$SRC/scripts/03_builtins.sh"
# shellcheck disable=SC1091
source "$SRC/scripts/04_musl.sh"
# shellcheck disable=SC1091
source "$SRC/scripts/05_llvm.sh"
# shellcheck disable=SC1091
source "$SRC/scripts/06_prune.sh"
# shellcheck disable=SC1091
source "$SRC/scripts/07_verify.sh"
# shellcheck disable=SC1091
source "$SRC/scripts/08_package.sh"

run_step() {
  local step="$1"
  case "$step" in
    bootstrap)
      step_bootstrap
      step_host_cxx
      ;;
    fetch)
      step_fetch
      ;;
    builtins)
      step_builtins
      ;;
    musl)
      step_musl
      ;;
    llvm)
      step_llvm
      ;;
    prune)
      step_prune
      ;;
    verify)
      step_verify
      ;;
    package)
      step_package
      ;;
    *)
      die "未知步骤: $step"
      ;;
  esac
}

# 单独步骤执行模式
if [ -n "$SELECTED_STEP" ]; then
  log "单独执行步骤: $SELECTED_STEP"
  run_step "$SELECTED_STEP"
  ok "步骤 $SELECTED_STEP 执行完毕"
  exit 0
fi

# 重新构建 LLVM 模式处理
if [ "$REBUILD_LLVM" = 1 ]; then
  unmark llvm
  unmark prune
  unmark verify
fi

# 标准流水线步骤序列
PIPELINE=(bootstrap fetch builtins musl llvm prune verify)

if [ "$ONLY_FETCH" = 1 ]; then
  PIPELINE=(bootstrap fetch)
fi

should_run=0
[ -z "$START_FROM" ] && should_run=1

for st in "${PIPELINE[@]}"; do
  if [ -n "$START_FROM" ] && [ "$st" = "$START_FROM" ]; then
    should_run=1
  fi
  if [ "$should_run" = 1 ]; then
    run_step "$st"
  fi
done

if [ "$DO_PACKAGE" = 1 ]; then
  run_step package
fi

log "全部流程已顺利完成！"
printf '工具链安装路径: %s\n' "$INSTALL"
printf '三元组别名调用: %s/bin/%s-clang hello.c\n' "$INSTALL" "$T"
printf '标准参数调用  : %s/bin/clang --target=%s --sysroot=%s hello.c\n' "$INSTALL" "$T" "$SYSROOT"
