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

组件与编译参数灵活定制 (支持自由组合子项目、MLIR 与额外参数):
  ./build.sh --projects <LIST>   指定要构建的 LLVM 子项目列表 (如 "clang;lld;mlir"，分号分隔)
  ./build.sh --enable-mlir       快捷启用 MLIR 子项目 (自动将 mlir 追加至构建列表)
  ./build.sh --enable-torch-mlir 快捷启用 MLIR 与 torch-mlir 完整流水线 (亦支持 --torch-mlir)
  ./build.sh --targets <LIST>    指定 LLVM 目标架构 (如 "RISCV;X86" 或 "all"，分号分隔)
  ./build.sh --runtimes <LIST>   指定 LLVM 目标端运行时列表 (分号分隔)
  ./build.sh --cmake-args <ARGS> 透传额外 CMake 参数至 LLVM (如 "-DLLVM_BUILD_EXAMPLES=OFF")
  ./build.sh --musl-args <ARGS>  透传额外配置参数至 Musl configure
  ./build.sh --torch-mlir-src <DIR> 挂载 torch-mlir 源码目录 (预留组件扩展)
  ./build.sh --llvm-src <DIR>    挂载本地自研 LLVM 源码目录 (无需重新拉取 Git)
  ./build.sh --musl-src <DIR>    挂载本地自研 Musl 源码目录 (无需重新拉取 Git)

辅助调试与控制开关:
  ./build.sh --assertions        显式开启 LLVM 断言 (精确定位 Pass 与 ISel 崩溃)
  ./build.sh --no-assertions     显式关闭 LLVM 断言
  ./build.sh --strip             强制剥离宿主程序符号 (Strip)
  ./build.sh --no-strip          保留宿主程序与库调试符号
  ./build.sh --torch-mlir-version <REF> 指定特定的 torch-mlir 版本/Commit (默认由 LLVM 版本自动对齐)
  ./build.sh --strict-versions    开启严格版本校验 (LLVM 与 torch-mlir 不匹配时报错中止)

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
  torch-mlir  - 配置并构建 torch-mlir 组件 (可扩展插件阶段)
  prune       - 精简无用跨平台工具、剥离符号、生成三元组链接与 .cfg
  verify      - 工具链运行库检查与 C/C++ 冒烟测试
  package     - 离线打包生成 .tar.zst 与 SHA256 校验和

常用组合示例:
  ./build.sh --default
  ./build.sh --enable-mlir --debug
  ./build.sh --projects "clang;lld;mlir" --targets "RISCV;X86" --debug
  ./build.sh --step llvm --debug --cmake-args "-DLLVM_BUILD_EXAMPLES=OFF"
  ./build.sh --step torch-mlir --torch-mlir-src /path/to/torch-mlir
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
CLI_LLVM_PROJECTS=""
CLI_ENABLE_MLIR=0
CLI_ENABLE_TORCH_MLIR=0
CLI_TORCH_MLIR_REF=""
CLI_STRICT_VERSIONS=0
CLI_LLVM_TARGETS=""
CLI_LLVM_RUNTIMES=""
CLI_LLVM_EXTRA_CMAKE_ARGS=()
CLI_MUSL_EXTRA_ARGS=()
CLI_TORCH_MLIR_SRC=""
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
      CLI_LLVM_PROJECTS=""
      CLI_ENABLE_MLIR=0
      CLI_ENABLE_TORCH_MLIR=0
      CLI_LLVM_TARGETS=""
      CLI_LLVM_RUNTIMES=""
      CLI_LLVM_EXTRA_CMAKE_ARGS=()
      CLI_MUSL_EXTRA_ARGS=()
      CLI_TORCH_MLIR_SRC=""
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
    --projects|--llvm-projects)
      [ -n "${2:-}" ] || die "$1 需要指定子项目列表 (如 \"clang;lld;mlir\")"
      CLI_LLVM_PROJECTS="$2"
      shift 2
      ;;
    --enable-mlir|--mlir)
      CLI_ENABLE_MLIR=1
      shift
      ;;
    --enable-torch-mlir|--torch-mlir)
      CLI_ENABLE_TORCH_MLIR=1
      CLI_ENABLE_MLIR=1
      shift
      ;;
    --targets|--llvm-targets|--targets-to-build)
      [ -n "${2:-}" ] || die "$1 需要指定目标架构列表 (如 \"RISCV;X86\")"
      CLI_LLVM_TARGETS="$2"
      shift 2
      ;;
    --runtimes|--llvm-runtimes)
      [ -n "${2:-}" ] || die "$1 需要指定目标运行库列表 (如 \"compiler-rt;libcxx;libcxxabi;libunwind\")"
      CLI_LLVM_RUNTIMES="$2"
      shift 2
      ;;
    --cmake-args|--llvm-cmake-args)
      [ -n "${2:-}" ] || die "$1 需要指定 CMake 额外参数 (如 \"-DLLVM_BUILD_EXAMPLES=OFF\")"
      CLI_LLVM_EXTRA_CMAKE_ARGS+=("$2")
      shift 2
      ;;
    --musl-args)
      [ -n "${2:-}" ] || die "$1 需要指定 Musl 额外配置参数"
      CLI_MUSL_EXTRA_ARGS+=("$2")
      shift 2
      ;;
    --torch-mlir-src)
      [ -n "${2:-}" ] || die "$1 需要指定 torch-mlir 源码目录"
      CLI_TORCH_MLIR_SRC="$2"
      shift 2
      ;;
    --torch-mlir-version|--torch-mlir-ref)
      [ -n "${2:-}" ] || die "$1 需要指定版本或 Commit SHA"
      CLI_TORCH_MLIR_REF="$2"
      shift 2
      ;;
    --strict-versions)
      CLI_STRICT_VERSIONS=1
      shift
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
[ -n "$CLI_LLVM_SRC" ]            && LLVM_SRC="$CLI_LLVM_SRC"
[ -n "$CLI_MUSL_SRC" ]            && MUSL_SRC="$CLI_MUSL_SRC"
[ -n "$CLI_TORCH_MLIR_SRC" ]      && TORCH_MLIR_SRC="$CLI_TORCH_MLIR_SRC"

# 编译参数灵活覆盖与扩展
[ -n "$CLI_LLVM_PROJECTS" ]       && LLVM_ENABLE_PROJECTS="$CLI_LLVM_PROJECTS"
[ -n "$CLI_LLVM_TARGETS" ]        && LLVM_TARGETS_TO_BUILD="$CLI_LLVM_TARGETS"
[ -n "$CLI_LLVM_RUNTIMES" ]       && LLVM_ENABLE_RUNTIMES="$CLI_LLVM_RUNTIMES"

# 若显式指定 --enable-mlir 或 --enable-torch-mlir，确保 mlir 被加入到 LLVM_ENABLE_PROJECTS 中
if [ "$CLI_ENABLE_MLIR" = 1 ] || [ "${CLI_ENABLE_TORCH_MLIR:-0}" = 1 ]; then
  if [[ ";${LLVM_ENABLE_PROJECTS};" != *";mlir;"* ]]; then
    LLVM_ENABLE_PROJECTS="${LLVM_ENABLE_PROJECTS};mlir"
  fi
  ENABLE_MLIR=1
fi
if [ "${CLI_ENABLE_TORCH_MLIR:-0}" = 1 ]; then
  ENABLE_TORCH_MLIR=1
fi
[ -n "${CLI_TORCH_MLIR_REF:-}" ] && TORCH_MLIR_SHA="$CLI_TORCH_MLIR_REF"
[ "${CLI_STRICT_VERSIONS:-0}" = 1 ] && STRICT_VERSIONS=1

# 拼接额外的 CMake 与 Musl 参数
if [ ${#CLI_LLVM_EXTRA_CMAKE_ARGS[@]} -gt 0 ]; then
  if [ -n "$LLVM_EXTRA_CMAKE_ARGS" ]; then
    LLVM_EXTRA_CMAKE_ARGS="${LLVM_EXTRA_CMAKE_ARGS} ${CLI_LLVM_EXTRA_CMAKE_ARGS[*]}"
  else
    LLVM_EXTRA_CMAKE_ARGS="${CLI_LLVM_EXTRA_CMAKE_ARGS[*]}"
  fi
fi
if [ ${#CLI_MUSL_EXTRA_ARGS[@]} -gt 0 ]; then
  if [ -n "$MUSL_EXTRA_ARGS" ]; then
    MUSL_EXTRA_ARGS="${MUSL_EXTRA_ARGS} ${CLI_MUSL_EXTRA_ARGS[*]}"
  else
    MUSL_EXTRA_ARGS="${CLI_MUSL_EXTRA_ARGS[*]}"
  fi
fi

# 默认规则：若指定了动态库(ENABLE_SHARED=ON)且未显式指定静态链接，则默认动态链接
if [ "$ENABLE_SHARED" = "ON" ] && [ -z "$CLI_DEFAULT_STATIC_LINK" ]; then
  DEFAULT_STATIC_LINK="OFF"
fi

# 若显式通过参数指定了自研源码变更，自动清理 fetch 时间戳以触发更新
if [ -n "$CLI_LLVM_SRC" ] || [ -n "$CLI_MUSL_SRC" ] || [ -n "$CLI_TORCH_MLIR_SRC" ]; then
  unmark fetch
fi

# ─── 前置检查 ────────────────────────────────────────────────────────────
[ -d "$SRC/linux-headers/include" ] || die "缺少 $SRC/linux-headers/include"
command -v curl >/dev/null || die "缺少 curl"
command -v tar  >/dev/null || die "缺少 tar"

printf '%s%s 无 GCC 工具链构建%s\n' "$c_hd" "$TARGET_TRIPLE" "$c_off"
printf '  SRC     = %s\n  INSTALL = %s\n  JOBS    = %s\n  BUILD   = %s (Runtimes: %s, Assertions: %s, Strip: %s, Shared: %s, DefaultStatic: %s)\n' "$SRC" "$INSTALL" "$JOBS" "$BUILD_TYPE" "$RUNTIMES_BUILD_TYPE" "$ENABLE_ASSERTIONS" "$STRIP_SYMBOLS" "$ENABLE_SHARED" "$DEFAULT_STATIC_LINK"
printf '  PROJECTS= %s\n  TARGETS = %s\n' "${LLVM_ENABLE_PROJECTS:-clang;lld}" "${LLVM_TARGETS_TO_BUILD:-$LLVM_TARGET_ARCH}"
[ -n "${LLVM_EXTRA_CMAKE_ARGS:-}" ] && printf '  CMAKE_EXTRA = %s\n' "$LLVM_EXTRA_CMAKE_ARGS"

# 引入所有步骤模块
# shellcheck disable=SC1091
source "$SRC/scripts/bootstrap.sh"
# shellcheck disable=SC1091
source "$SRC/scripts/fetch.sh"
# shellcheck disable=SC1091
source "$SRC/scripts/builtins.sh"
# shellcheck disable=SC1091
source "$SRC/scripts/musl.sh"
# shellcheck disable=SC1091
source "$SRC/scripts/llvm.sh"
# shellcheck disable=SC1091
source "$SRC/scripts/torch_mlir.sh"
# shellcheck disable=SC1091
source "$SRC/scripts/prune.sh"
# shellcheck disable=SC1091
source "$SRC/scripts/verify.sh"
# shellcheck disable=SC1091
source "$SRC/scripts/package.sh"

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
    torch-mlir|torch_mlir)
      step_torch_mlir
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
if [ "${ENABLE_TORCH_MLIR:-0}" = 1 ] || [ "${CLI_ENABLE_TORCH_MLIR:-0}" = 1 ]; then
  PIPELINE=(bootstrap fetch builtins musl llvm torch-mlir prune verify)
fi

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
