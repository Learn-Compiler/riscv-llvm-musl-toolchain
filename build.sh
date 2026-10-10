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
  ./build.sh [选项...]

构建模式选择:
  ./build.sh                     完整构建（默认：Release 模式，纯静态库，默认静态链接）
  ./build.sh --default           恢复/强制默认标准构建（Release + 静态库 + 默认静态链接）
  ./build.sh --release           发布优化模式 (Release -O3 + 剥离符号)
  ./build.sh --debug             二次开发推荐调试模式 (RelWithDebInfo -O2 -g + Assertions + 保留符号)
  ./build.sh --full-debug        单步源码级纯调试模式 (Debug -O0 -g + Assertions + 保留符号)
  ./build.sh --build-type <TYPE> 自定义 CMake 构建模式 (Release|RelWithDebInfo|Debug|MinSizeRel)
  ./build.sh --runtimes-build-type <TYPE> 自定义目标端运行库构建模式 (默认: Release)

库类型与链接模式 (默认未指定为静态库，指定后为动态库):
  ./build.sh --shared, --share   编译目标共享库 (.so) 与静态库 (.a)，工具链默认动态链接
  ./build.sh --static            显式指定仅编译目标静态库 (.a)（默认行为）
  ./build.sh --static-link       工具链 .cfg 配置文件中默认追加 -static 静态链接 (静态库下默认开启)
  ./build.sh --no-static-link    工具链 .cfg 配置文件中不默认追加 -static (亦支持 --no-default-static)

组件版本与源码路径 (自由组合定制库版本与分支):
  ./build.sh --llvm-version <VER> 指定 LLVM 版本/分支/标签/Commit (如 20, 19, release/19.x, main, llvmorg-19.1.0)
  ./build.sh --musl-version <VER> 指定 Musl 版本/分支/标签/Commit (如 1.2.5, v1.2.5, master)
  ./build.sh --llvm-src <DIR>     挂载本地 LLVM 自研源码目录 (无需重新拉取 Git)
  ./build.sh --musl-src <DIR>     挂载本地 Musl 自研源码目录 (无需重新拉取 Git)

辅助调试与控制开关:
  ./build.sh --assertions        显式开启 LLVM 断言 (精确定位 Pass 与 ISel 崩溃)
  ./build.sh --no-assertions     显式关闭 LLVM 断言
  ./build.sh --strip             强制剥离宿主程序符号 (Strip)
  ./build.sh --no-strip          保留宿主程序与库调试符号

模块流水线与维护选项:
  ./build.sh --step <步骤名>     单独执行某一特定步骤 (可多次指定，如 --step musl --step llvm)
  ./build.sh --from <步骤名>     从指定步骤开始向下连续执行
  ./build.sh --rebuild-llvm      重新编译 LLVM 模块与运行库（二次开发常用）
  ./build.sh --fetch             仅准备自举工具并拉取源码
  ./build.sh --package           构建完成后打包生成 .tar.zst 离线发布包
  ./build.sh --clean             清理编译临时目录与时间戳（保留 .bootstrap）
  ./build.sh --clean-all         清理所有内容（包括 .bootstrap 引导工具）
  ./build.sh --target <目标名>   指定目标平台配置 (对应 config/targets/<目标名>.env)
  JOBS=8 ./build.sh              指定并行构建核心数 (默认 6)

可选步骤名列表:
  bootstrap   - 准备免 root 引导工具并探测宿主 C++
  fetch       - 拉取源码或挂载本地自研源码 (llvm, musl)
  builtins    - 编译 compiler-rt builtins 与 crt (亦支持别名 --step compiler-rt)
  musl        - 编译 Musl libc 并安装至 Sysroot
  llvm        - 编译 LLVM/Clang 及全部运行时 (libc++/libunwind)
  prune       - 精简无用跨平台工具、剥离符号、生成三元组链接与 .cfg
  verify      - 工具链运行库检查与 C/C++ 冒烟测试
  package     - 离线打包生成 .tar.zst 与 SHA256 校验和

常用组合示例:
  ./build.sh --default
  ./build.sh --release
  ./build.sh --debug
  ./build.sh --shared
  ./build.sh --step llvm --debug
  ./build.sh --step musl --release --share
EOF
  exit 0
}

# ─── 参数解析 ────────────────────────────────────────────────────────────
ONLY_FETCH=0
DO_PACKAGE=0
REBUILD_LLVM=0
SELECTED_STEPS=()
START_FROM=""
CLI_BUILD_TYPE=""
CLI_RUNTIMES_BUILD_TYPE=""
CLI_ASSERTIONS=""
CLI_STRIP_SYMBOLS=""
CLI_ENABLE_SHARED=""
CLI_DEFAULT_STATIC_LINK=""
CLI_LLVM_VERSION=""
CLI_MUSL_VERSION=""
CLI_LLVM_SRC=""
CLI_MUSL_SRC=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      show_help
      ;;
    --default)
      CLI_BUILD_TYPE="Release"
      CLI_RUNTIMES_BUILD_TYPE="Release"
      CLI_ASSERTIONS="OFF"
      CLI_STRIP_SYMBOLS="AUTO"
      CLI_ENABLE_SHARED="OFF"
      CLI_DEFAULT_STATIC_LINK="ON"
      CLI_LLVM_VERSION=""
      CLI_MUSL_VERSION=""
      CLI_LLVM_SRC=""
      CLI_MUSL_SRC=""
      shift
      ;;
    --release|--realse)
      CLI_BUILD_TYPE="Release"
      shift
      ;;
    --debug)
      CLI_BUILD_TYPE="RelWithDebInfo"
      CLI_ASSERTIONS="ON"
      CLI_STRIP_SYMBOLS="OFF"
      shift
      ;;
    --full-debug)
      CLI_BUILD_TYPE="Debug"
      CLI_ASSERTIONS="ON"
      CLI_STRIP_SYMBOLS="OFF"
      shift
      ;;
    --assertions)
      CLI_ASSERTIONS="ON"
      shift
      ;;
    --no-assertions)
      CLI_ASSERTIONS="OFF"
      shift
      ;;
    --build-type)
      [ -n "${2:-}" ] || die "--build-type 需要指定模式 (Release|RelWithDebInfo|Debug|MinSizeRel)"
      CLI_BUILD_TYPE="$2"
      shift 2
      ;;
    --runtimes-build-type)
      [ -n "${2:-}" ] || die "--runtimes-build-type 需要指定模式 (Release|RelWithDebInfo|Debug|MinSizeRel)"
      CLI_RUNTIMES_BUILD_TYPE="$2"
      shift 2
      ;;
    --llvm-version|--llvm-ver|--llvm-ref)
      [ -n "${2:-}" ] || die "$1 需要指定版本/分支/Commit (如 20, 19, release/19.x, main, llvmorg-19.1.0)"
      CLI_LLVM_VERSION="$2"
      shift 2
      ;;
    --musl-version|--musl-ver|--musl-ref)
      [ -n "${2:-}" ] || die "$1 需要指定版本/分支/Commit (如 1.2.5, v1.2.5, master)"
      CLI_MUSL_VERSION="$2"
      shift 2
      ;;
    --llvm-src)
      [ -n "${2:-}" ] || die "--llvm-src 需要指定源码目录"
      CLI_LLVM_SRC="$2"
      shift 2
      ;;
    --musl-src)
      [ -n "${2:-}" ] || die "--musl-src 需要指定源码目录"
      CLI_MUSL_SRC="$2"
      shift 2
      ;;
    --strip)
      CLI_STRIP_SYMBOLS="ON"
      shift
      ;;
    --no-strip)
      CLI_STRIP_SYMBOLS="OFF"
      shift
      ;;
    --shared|--share)
      CLI_ENABLE_SHARED="ON"
      shift
      ;;
    --static)
      CLI_ENABLE_SHARED="OFF"
      shift
      ;;
    --static-link)
      CLI_DEFAULT_STATIC_LINK="ON"
      shift
      ;;
    --no-static-link|--no-default-static)
      CLI_DEFAULT_STATIC_LINK="OFF"
      shift
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
      SELECTED_STEPS+=("$2")
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
[ -n "$CLI_BUILD_TYPE" ]          && BUILD_TYPE="$CLI_BUILD_TYPE"
[ -n "$CLI_RUNTIMES_BUILD_TYPE" ] && RUNTIMES_BUILD_TYPE="$CLI_RUNTIMES_BUILD_TYPE"
[ -n "$CLI_ASSERTIONS" ]          && ENABLE_ASSERTIONS="$CLI_ASSERTIONS"
[ -n "$CLI_STRIP_SYMBOLS" ]       && STRIP_SYMBOLS="$CLI_STRIP_SYMBOLS"
[ -n "$CLI_ENABLE_SHARED" ]       && ENABLE_SHARED="$CLI_ENABLE_SHARED"
[ -n "$CLI_DEFAULT_STATIC_LINK" ] && DEFAULT_STATIC_LINK="$CLI_DEFAULT_STATIC_LINK"
[ -n "$CLI_LLVM_VERSION" ]        && LLVM_VERSION="$CLI_LLVM_VERSION"
[ -n "$CLI_MUSL_VERSION" ]        && MUSL_VERSION="$CLI_MUSL_VERSION"
[ -n "$CLI_LLVM_SRC" ]            && LLVM_SRC="$CLI_LLVM_SRC"
[ -n "$CLI_MUSL_SRC" ]            && MUSL_SRC="$CLI_MUSL_SRC"

# 默认规则：若指定了动态库(ENABLE_SHARED=ON)且未显式指定静态链接，则默认动态链接
if [ "$ENABLE_SHARED" = "ON" ] && [ -z "$CLI_DEFAULT_STATIC_LINK" ]; then
  DEFAULT_STATIC_LINK="OFF"
fi

# 若显式通过参数指定了组件版本或自研源码变更，自动清理 fetch 时间戳以触发更新检出
if [ -n "$CLI_LLVM_VERSION" ] || [ -n "$CLI_MUSL_VERSION" ] || [ -n "$CLI_LLVM_SRC" ] || [ -n "$CLI_MUSL_SRC" ]; then
  unmark fetch
fi

# ─── 前置检查 ────────────────────────────────────────────────────────────
[ -d "$SRC/linux-headers/include" ] || die "缺少 $SRC/linux-headers/include"
command -v curl >/dev/null || die "缺少 curl"
command -v tar  >/dev/null || die "缺少 tar"

printf '%s%s 无 GCC 工具链构建%s\n' "$c_hd" "$TARGET_TRIPLE" "$c_off"
printf '  SRC     = %s\n  INSTALL = %s\n  JOBS    = %s\n  BUILD   = %s (Runtimes: %s, Assertions: %s, Strip: %s, Shared: %s, DefaultStatic: %s)\n' "$SRC" "$INSTALL" "$JOBS" "$BUILD_TYPE" "$RUNTIMES_BUILD_TYPE" "$ENABLE_ASSERTIONS" "$STRIP_SYMBOLS" "$ENABLE_SHARED" "$DEFAULT_STATIC_LINK"
printf '  LLVM    = %s\n  MUSL    = %s\n' "${LLVM_SRC:-${LLVM_VERSION:-submodule default}}" "${MUSL_SRC:-${MUSL_VERSION:-submodule default}}"

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
    builtins|compiler-rt|compiler_rt)
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

# 单独步骤执行模式（支持单个或按序指定多个步骤，如 --step musl --step llvm）
if [ ${#SELECTED_STEPS[@]} -gt 0 ]; then
  for step in "${SELECTED_STEPS[@]}"; do
    [ "$step" = "compiler-rt" ] || [ "$step" = "compiler_rt" ] && step="builtins"
    unmark "$step"
    log "单独执行步骤: $step"
    run_step "$step"
    ok "步骤 $step 执行完毕"
  done
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
[ "$START_FROM" = "compiler-rt" ] || [ "$START_FROM" = "compiler_rt" ] && START_FROM="builtins"
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
