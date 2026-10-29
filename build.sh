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
BUILD_START_TIME=$(date +%s)

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
  ./build.sh --enable-triton     快捷启用 MLIR 与 Triton 完整流水线 (亦支持 --triton)
  ./build.sh --targets <LIST>    指定 LLVM 目标架构 (如 "RISCV;X86" 或 "all"，分号分隔)
  ./build.sh --runtimes <LIST>   指定 LLVM 目标端运行时列表 (分号分隔)
  ./build.sh --cmake-args <ARGS> 透传额外 CMake 参数至 LLVM (如 "-DLLVM_BUILD_EXAMPLES=OFF")
  ./build.sh --musl-args <ARGS>  透传额外配置参数至 Musl configure
  ./build.sh --torch-mlir-src <DIR> 挂载 torch-mlir 源码目录 (预留组件扩展)
  ./build.sh --triton-src <DIR>     挂载 Triton 源码目录 (预留 AI 编译器扩展)
  ./build.sh --llvm-src <DIR>    挂载本地自研 LLVM 源码目录 (无需重新拉取 Git)
  ./build.sh --musl-src <DIR>    挂载本地自研 Musl 源码目录 (无需重新拉取 Git)

辅助调试与控制开关:
  ./build.sh --assertions        显式开启 LLVM 断言 (精确定位 Pass 与 ISel 崩溃)
  ./build.sh --no-assertions     显式关闭 LLVM 断言
  ./build.sh --strip             强制剥离宿主程序符号 (Strip)
  ./build.sh --no-strip          保留宿主程序与库调试符号
  ./build.sh --llvm-version <REF>       指定 LLVM 版本/分支/Tag/Commit (默认: config/versions.lock)
  ./build.sh --torch-mlir-version <REF> 指定 torch-mlir 版本/分支/Tag/Commit
  ./build.sh --triton-version <REF>     指定 Triton 版本/分支/Tag/Commit (默认: config/versions.lock)
  ./build.sh --musl-version <REF>       指定 Musl 版本/分支/Tag/Commit (默认: v1.2.5)
  ./build.sh --linux-headers-version <REF> 指定 linux-headers 版本/分支/Tag (默认: master)
  ./build.sh --strict-versions          开启严格版本校验 (LLVM 与 torch-mlir 不匹配时报错中止)

模块流水线与维护选项:
  ./build.sh --step <步骤名>     单独执行某一特定步骤 (可多次指定，如 --step musl --step compiler-rt)
  ./build.sh --from <步骤名>     从指定步骤开始向下连续执行
  -j, --jobs <N>                 指定并行构建核心数 (默认 auto: 依据 CPU 与内存自适应计算)
  --ccache                       强制启用 ccache 编译加速 (若宿主无则自动下载免 root 引导版本)
  --no-ccache                    禁用 ccache 编译加速
  ./build.sh --rebuild-llvm      重新编译 LLVM 模块与运行库（二次开发常用）
  ./build.sh --fetch             仅准备自举工具并拉取源码
  ./build.sh --package           构建完成后打包生成 .tar.zst 离线发布包
  ./build.sh --clean             清理编译临时目录与时间戳（保留 .bootstrap）
  ./build.sh --clean-all         清理所有内容（包括 .bootstrap 引导工具）
  ./build.sh --target <目标名>   指定目标平台配置 (支持 riscv32-unknown-linux-musl, riscv64-linux-musl 等)
  ./build.sh --riscv32, --rv32   快捷切换目标平台为 RISC-V 32 (riscv32-unknown-linux-musl)
  ./build.sh --riscv64, --rv64   快捷切换目标平台为 RISC-V 64 (riscv64-unknown-linux-musl，默认)
  ./build.sh --multilib-rv32     双架构模式：构建 64 位工具链同时追加编译 32 位完整运行库
  ./build.sh --sysroot <DIR>     自定义指定目标 Sysroot 安装/检索目录

可选步骤名列表:
  bootstrap        - 准备免 root 引导工具并探测宿主 C++
  fetch            - 拉取源码或挂载本地自研源码 (llvm, musl, torch-mlir, triton)
  llvm             - 编译 LLVM 核心编译器工具 (clang/lld/llvm-ar 等)
  musl             - 独立编译目标 C 运行库 Musl (libc.a) 并准备 Linux 头文件
  compiler-rt      - 独立编译目标编译器基础运行库 (builtins / crtbegin / crtend)
  libc++           - 独立编译目标 C++ 运行时 (libunwind / libc++ / libc++abi)
  runtimes         - 编排并编译目标端全套运行时 (musl -> compiler-rt -> libc++)
  musl-rv32        - 独立为 riscv32 编译目标 C 运行库 Musl (libc.a)
  compiler-rt-rv32 - 独立为 riscv32 编译目标基础运行库 (builtins / crt)
  libc++-rv32      - 独立为 riscv32 编译目标 C++ 运行时 (libc++ / libunwind)
  runtimes-rv32    - 独立编译 riscv32 全套运行时并配置 riscv32-unknown-linux-musl.cfg
  verify-rv32      - 独立对 riscv32 目标运行库与 C/C++ 进行冒烟测试
  torch-mlir       - 配置并构建 torch-mlir 组件 (可扩展插件阶段)
  triton           - 配置并构建 Triton 组件 (可扩展 AI 编译器插件阶段)
  prune            - 精简无用跨平台工具、剥离符号、生成三元组链接与 .cfg
  verify           - 工具链运行库检查与 C/C++ 冒烟测试
  package          - 离线打包生成 .tar.zst 与 SHA256 校验和

常用组合示例:
  ./build.sh --default
  ./build.sh --riscv32 --default
  ./build.sh --multilib-rv32
  ./build.sh --step runtimes-rv32
  ./build.sh --enable-mlir --debug
  ./build.sh --enable-triton
  ./build.sh --projects "clang;lld;mlir" --targets "RISCV;X86" --debug
  ./build.sh --step llvm --debug --cmake-args "-DLLVM_BUILD_EXAMPLES=OFF"
  ./build.sh --step torch-mlir --torch-mlir-src /path/to/torch-mlir
  ./build.sh --step triton --triton-src /path/to/triton
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
CLI_RUNTIMES_OPT_LEVEL=""
CLI_ASSERTIONS=""
CLI_STRIP_SYMBOLS=""
CLI_ENABLE_SHARED=""
CLI_DEFAULT_STATIC_LINK=""
CLI_LLVM_PROJECTS=""
CLI_ENABLE_MLIR=0
CLI_ENABLE_TORCH_MLIR=0
CLI_ENABLE_TRITON=0
CLI_LLVM_REF=""
CLI_TORCH_MLIR_REF=""
CLI_TRITON_REF=""
CLI_MUSL_REF=""
CLI_STRICT_VERSIONS=0
CLI_LLVM_TARGETS=""
CLI_LLVM_RUNTIMES=""
CLI_LLVM_EXTRA_CMAKE_ARGS=()
CLI_MUSL_EXTRA_ARGS=()
CLI_TORCH_MLIR_SRC=""
CLI_TRITON_SRC=""
CLI_TRITON_EXTRA_CMAKE_ARGS=()
CLI_LLVM_SRC=""
CLI_MUSL_SRC=""
CLI_LINUX_HEADERS_REF=""
CLI_LINUX_HEADERS_SRC=""
CLI_JOBS=""
CLI_ENABLE_CCACHE=""
CLI_INSTALL_TOOLCHAIN=""
CLI_INSTALL_AI=""
CLI_TARGET=""
CLI_ENABLE_RV32=0
CLI_SYSROOT=""

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
      CLI_ENABLE_TRITON=0
      CLI_LLVM_TARGETS=""
      CLI_LLVM_RUNTIMES=""
      CLI_LLVM_EXTRA_CMAKE_ARGS=()
      CLI_MUSL_EXTRA_ARGS=()
      CLI_TORCH_MLIR_SRC=""
      CLI_TRITON_SRC=""
      CLI_TRITON_EXTRA_CMAKE_ARGS=()
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
    --runtimes-opt|--runtimes-opt-level)
      [ -n "${2:-}" ] || die "$1 需要指定优化级别 (如 \"-O2\" 或 \"-O3\")"
      if [[ "$2" != -* ]]; then
        CLI_RUNTIMES_OPT_LEVEL="-$2"
      else
        CLI_RUNTIMES_OPT_LEVEL="$2"
      fi
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
    --enable-triton|--triton)
      CLI_ENABLE_TRITON=1
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
    --triton-src)
      [ -n "${2:-}" ] || die "$1 需要指定 triton 源码目录"
      CLI_TRITON_SRC="$2"
      shift 2
      ;;
    --triton-args)
      [ -n "${2:-}" ] || die "$1 需要指定 Triton 额外 CMake 参数"
      CLI_TRITON_EXTRA_CMAKE_ARGS+=("$2")
      shift 2
      ;;
    --llvm-version|--llvm-ref)
      [ -n "${2:-}" ] || die "$1 需要指定 LLVM 版本 (如 \"release/23.x\"、\"llvmorg-23.1.3\" 或 Commit SHA)"
      CLI_LLVM_REF="$2"
      shift 2
      ;;
    --torch-mlir-version|--torch-mlir-ref)
      [ -n "${2:-}" ] || die "$1 需要指定 torch-mlir 版本或 Commit SHA"
      CLI_TORCH_MLIR_REF="$2"
      shift 2
      ;;
    --triton-version|--triton-ref)
      [ -n "${2:-}" ] || die "$1 需要指定 Triton 版本或 Tag (默认: config/versions.lock)"
      CLI_TRITON_REF="$2"
      shift 2
      ;;
    --musl-version|--musl-ref)
      [ -n "${2:-}" ] || die "$1 需要指定 Musl 版本或 Tag (如 \"v1.2.5\")"
      CLI_MUSL_REF="$2"
      shift 2
      ;;
    --linux-headers-version|--linux-headers-ref)
      [ -n "${2:-}" ] || die "$1 需要指定 linux-headers 版本或分支 (如 \"master\")"
      CLI_LINUX_HEADERS_REF="$2"
      shift 2
      ;;
    --linux-headers-src)
      [ -n "${2:-}" ] || die "--linux-headers-src 需要指定源码目录"
      CLI_LINUX_HEADERS_SRC="$2"
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
    -j)
      [ -n "${2:-}" ] || die "-j 需要指定线程数"
      CLI_JOBS="$2"
      shift 2
      ;;
    --jobs)
      [ -n "${2:-}" ] || die "--jobs 需要指定线程数"
      CLI_JOBS="$2"
      shift 2
      ;;
    --jobs=*)
      CLI_JOBS="${1#*=}"
      shift
      ;;
    -j*)
      CLI_JOBS="${1#-j}"
      shift
      ;;
    --ccache)
      CLI_ENABLE_CCACHE="ON"
      shift
      ;;
    --no-ccache)
      CLI_ENABLE_CCACHE="OFF"
      shift
      ;;
    --install-toolchain|--install-dir)
      [ -n "${2:-}" ] || die "$1 需要指定目录"
      CLI_INSTALL_TOOLCHAIN="$2"
      shift 2
      ;;
    --install-ai)
      [ -n "${2:-}" ] || die "$1 需要指定目录"
      CLI_INSTALL_AI="$2"
      shift 2
      ;;
    --target)
      [ -n "${2:-}" ] || die "--target 需要指定目标名称 (如 riscv32-unknown-linux-musl, riscv64-linux-musl)"
      CLI_TARGET="$2"
      shift 2
      ;;
    --riscv32|--rv32)
      CLI_TARGET="riscv32-linux-musl"
      shift
      ;;
    --riscv64|--rv64)
      CLI_TARGET="riscv64-linux-musl"
      shift
      ;;
    --multilib-rv32|--enable-rv32|--with-rv32)
      CLI_ENABLE_RV32=1
      shift
      ;;
    --sysroot)
      [ -n "${2:-}" ] || die "$1 需要指定 sysroot 路径"
      CLI_SYSROOT="$2"
      shift 2
      ;;
    --clean)
      log "清理构建缓存与时间戳 ..."
      rm -rf "$STAMPS" "$BUILD_DIR" "$BUILD" "$SRC/build-compiler-rt" "$SRC/build-runtimes"* "$SRC/build-torch-mlir" "$SRC/build-triton" "${INSTALL_TOOLCHAIN:-$INSTALL}" "${INSTALL_AI:-$SRC/install-ai}" "$SRC/install-clang-musl" "$SRC/env.sh" "$SHIM"
      ok "清理完成"
      exit 0
      ;;
    --clean-all)
      log "完全清理构建缓存与引导环境 ..."
      rm -rf "$STAMPS" "$BUILD_DIR" "$BUILD" "$SRC/build-compiler-rt" "$SRC/build-runtimes"* "$SRC/build-torch-mlir" "$SRC/build-triton" "${INSTALL_TOOLCHAIN:-$INSTALL}" "${INSTALL_AI:-$SRC/install-ai}" "$SRC/install-clang-musl" "$SRC/env.sh" "$SHIM" "$BOOT"
      ok "全部清理完成"
      exit 0
      ;;
    *)
      die "未知参数: $1 (运行 ./build.sh --help 查看说明)"
      ;;
  esac
done

# 初始化基础配置与目标平台
[ -n "${CLI_TARGET:-}" ] && TARGET="$CLI_TARGET"
[ -n "${CLI_SYSROOT:-}" ] && { SYSROOT="$CLI_SYSROOT"; SYSROOT_OVERRIDDEN=1; }
init_config
[ -n "$CLI_JOBS" ]                && JOBS="$CLI_JOBS"
[ -n "$CLI_ENABLE_CCACHE" ]       && ENABLE_CCACHE="$CLI_ENABLE_CCACHE"
[ -n "${CLI_INSTALL_TOOLCHAIN:-}" ] && { INSTALL_TOOLCHAIN="$CLI_INSTALL_TOOLCHAIN"; INSTALL="$CLI_INSTALL_TOOLCHAIN"; }
[ -n "${CLI_INSTALL_AI:-}" ]        && INSTALL_AI="$CLI_INSTALL_AI"
[ -n "$CLI_BUILD_TYPE" ]          && BUILD_TYPE="$CLI_BUILD_TYPE"
[ -n "$CLI_RUNTIMES_BUILD_TYPE" ] && RUNTIMES_BUILD_TYPE="$CLI_RUNTIMES_BUILD_TYPE"
[ -n "$CLI_RUNTIMES_OPT_LEVEL" ]   && RUNTIMES_OPT_LEVEL="$CLI_RUNTIMES_OPT_LEVEL"
[ -n "$CLI_ASSERTIONS" ]          && ENABLE_ASSERTIONS="$CLI_ASSERTIONS"
[ -n "$CLI_STRIP_SYMBOLS" ]       && STRIP_SYMBOLS="$CLI_STRIP_SYMBOLS"
[ -n "$CLI_ENABLE_SHARED" ]       && ENABLE_SHARED="$CLI_ENABLE_SHARED"
[ -n "$CLI_DEFAULT_STATIC_LINK" ] && DEFAULT_STATIC_LINK="$CLI_DEFAULT_STATIC_LINK"
[ -n "$CLI_LLVM_SRC" ]            && LLVM_SRC="$CLI_LLVM_SRC"
[ -n "$CLI_MUSL_SRC" ]            && MUSL_SRC="$CLI_MUSL_SRC"
[ -n "$CLI_TORCH_MLIR_SRC" ]      && TORCH_MLIR_SRC="$CLI_TORCH_MLIR_SRC"
[ -n "$CLI_TRITON_SRC" ]          && TRITON_SRC="$CLI_TRITON_SRC"

# 编译参数灵活覆盖与扩展
[ -n "$CLI_LLVM_PROJECTS" ]       && LLVM_ENABLE_PROJECTS="$CLI_LLVM_PROJECTS"
[ -n "$CLI_LLVM_TARGETS" ]        && LLVM_TARGETS_TO_BUILD="$CLI_LLVM_TARGETS"
[ -n "$CLI_LLVM_RUNTIMES" ]       && LLVM_ENABLE_RUNTIMES="$CLI_LLVM_RUNTIMES"

# 若显式指定 --enable-mlir、--enable-torch-mlir 或 --enable-triton，确保 mlir 被加入到 LLVM_ENABLE_PROJECTS 中
if [ "$CLI_ENABLE_MLIR" = 1 ] || [ "${CLI_ENABLE_TORCH_MLIR:-0}" = 1 ] || [ "${CLI_ENABLE_TRITON:-0}" = 1 ]; then
  if [[ ";${LLVM_ENABLE_PROJECTS};" != *";mlir;"* ]]; then
    LLVM_ENABLE_PROJECTS="${LLVM_ENABLE_PROJECTS};mlir"
  fi
  ENABLE_MLIR=1
fi
if [ "${CLI_ENABLE_TORCH_MLIR:-0}" = 1 ]; then
  ENABLE_TORCH_MLIR=1
fi
if [ "${CLI_ENABLE_TRITON:-0}" = 1 ]; then
  ENABLE_TRITON=1
fi
[ -n "${CLI_LLVM_REF:-}" ]       && LLVM_REF="$CLI_LLVM_REF"
[ -n "${CLI_TORCH_MLIR_REF:-}" ] && TORCH_MLIR_REF="$CLI_TORCH_MLIR_REF"
[ -n "${CLI_TRITON_REF:-}" ]     && TRITON_REF="$CLI_TRITON_REF"
[ -n "${CLI_MUSL_REF:-}" ]       && MUSL_REF="$CLI_MUSL_REF"
[ -n "${CLI_LINUX_HEADERS_REF:-}" ] && LINUX_HEADERS_REF="$CLI_LINUX_HEADERS_REF"
[ "${CLI_STRICT_VERSIONS:-0}" = 1 ] && STRICT_VERSIONS=1

# 拼接额外的 CMake 与 Musl 参数
if [ ${#CLI_LLVM_EXTRA_CMAKE_ARGS[@]} -gt 0 ]; then
  if [ -n "$LLVM_EXTRA_CMAKE_ARGS" ]; then
    LLVM_EXTRA_CMAKE_ARGS="${LLVM_EXTRA_CMAKE_ARGS} ${CLI_LLVM_EXTRA_CMAKE_ARGS[*]}"
  else
    LLVM_EXTRA_CMAKE_ARGS="${CLI_LLVM_EXTRA_CMAKE_ARGS[*]}"
  fi
fi
if [ ${#CLI_TRITON_EXTRA_CMAKE_ARGS[@]} -gt 0 ]; then
  if [ -n "${TRITON_EXTRA_CMAKE_ARGS:-}" ]; then
    TRITON_EXTRA_CMAKE_ARGS="${TRITON_EXTRA_CMAKE_ARGS} ${CLI_TRITON_EXTRA_CMAKE_ARGS[*]}"
  else
    TRITON_EXTRA_CMAKE_ARGS="${CLI_TRITON_EXTRA_CMAKE_ARGS[*]}"
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

# 动态版本状态检测：若当前版本配置与上次构建状态不一致，自动清除相关时间戳
CURRENT_VER_STATE="LLVM=${LLVM_REF:-}|TORCH=${TORCH_MLIR_REF:-}|TRITON=${TRITON_REF:-}|MUSL=${MUSL_REF:-}|HDRS=${LINUX_HEADERS_REF:-}"
if [ -f "$STAMPS/.versions_state" ]; then
  PREV_VER_STATE="$(cat "$STAMPS/.versions_state" 2>/dev/null || true)"
  if [ "$CURRENT_VER_STATE" != "$PREV_VER_STATE" ]; then
    warn "检测到版本配置变动，自动重置受影响构建步骤 ($PREV_VER_STATE -> $CURRENT_VER_STATE)"
    unmark fetch
    unmark builtins
    unmark llvm
    unmark torch_mlir
    unmark triton
    unmark prune
    unmark verify
  fi
else
  # 首次初始化版本状态跟踪：不盲目清除已就绪的基础组件时间戳
  if ! [ -f "$SRC/third_party/llvm/llvm/CMakeLists.txt" ]; then
    unmark fetch
  fi
fi

# 检查实际检出的 Git 版本与当前配置是否一致（防止未拉取新版本导致与旧 LLVM 头文件不匹配）
if [ -f "$SRC/third_party/llvm/.git_checked_ref" ]; then
  CHECKED_LLVM_REF="$(cat "$SRC/third_party/llvm/.git_checked_ref" 2>/dev/null || true)"
  if [ -n "$CHECKED_LLVM_REF" ] && [ -n "${LLVM_REF:-}" ] && [ "$CHECKED_LLVM_REF" != "$LLVM_REF" ]; then
    warn "检测到 third_party/llvm 实际版本 ($CHECKED_LLVM_REF) 与配置 ($LLVM_REF) 不一致，重置构建步骤"
    unmark fetch
    unmark builtins
    unmark llvm
    unmark torch_mlir
    unmark triton
    unmark prune
    unmark verify
    rm -rf "$BUILD_DIR/build-torch-mlir" "$BUILD_DIR/build-triton" "$SRC/build-torch-mlir" "$SRC/build-triton"
  fi
fi
if [ -f "$SRC/third_party/torch-mlir/.git_checked_ref" ]; then
  CHECKED_TORCH_REF="$(cat "$SRC/third_party/torch-mlir/.git_checked_ref" 2>/dev/null || true)"
  if [ -n "$CHECKED_TORCH_REF" ] && [ -n "${TORCH_MLIR_REF:-}" ] && [ "$CHECKED_TORCH_REF" != "$TORCH_MLIR_REF" ]; then
    warn "检测到 torch-mlir 实际版本 ($CHECKED_TORCH_REF) 与配置 ($TORCH_MLIR_REF) 不一致，重置源码与构建步骤"
    unmark fetch
    unmark torch_mlir
    rm -rf "$BUILD_DIR/build-torch-mlir" "$SRC/build-torch-mlir"
  fi
fi
if [ -f "$SRC/third_party/triton/.git_checked_ref" ]; then
  CHECKED_TRITON_REF="$(cat "$SRC/third_party/triton/.git_checked_ref" 2>/dev/null || true)"
  if [ -n "$CHECKED_TRITON_REF" ] && [ -n "${TRITON_REF:-}" ] && [ "$CHECKED_TRITON_REF" != "$TRITON_REF" ]; then
    warn "检测到 triton 实际版本 ($CHECKED_TRITON_REF) 与配置 ($TRITON_REF) 不一致，重置源码与构建步骤"
    unmark fetch
    unmark triton
    rm -rf "$BUILD_DIR/build-triton" "$SRC/build-triton"
  fi
fi
mkdir -p "$STAMPS"
echo "$CURRENT_VER_STATE" > "$STAMPS/.versions_state"

# 若显式通过参数指定了自研源码或特定版本变更，自动清理 fetch 时间戳以触发更新
if [ -n "$CLI_LLVM_SRC" ] || [ -n "$CLI_MUSL_SRC" ] || [ -n "$CLI_TORCH_MLIR_SRC" ] || [ -n "$CLI_TRITON_SRC" ] || [ -n "$CLI_LINUX_HEADERS_SRC" ] || \
   [ -n "$CLI_LLVM_REF" ] || [ -n "$CLI_TORCH_MLIR_REF" ] || [ -n "$CLI_TRITON_REF" ] || [ -n "$CLI_MUSL_REF" ] || [ -n "$CLI_LINUX_HEADERS_REF" ]; then
  unmark fetch
fi
if [ -n "$CLI_LLVM_REF" ]; then
  unmark builtins
  unmark llvm
  unmark torch_mlir
  unmark triton
fi
if [ -n "$CLI_TORCH_MLIR_REF" ]; then
  unmark torch_mlir
fi
if [ -n "$CLI_TRITON_REF" ]; then
  unmark triton
fi

# ─── 前置检查 ────────────────────────────────────────────────────────────
command -v curl >/dev/null || die "缺少 curl"
command -v tar  >/dev/null || die "缺少 tar"

printf '%s%s 无 GCC 工具链构建%s\n' "$c_hd" "$TARGET_TRIPLE" "$c_off"
printf '  SRC     = %s\n  INSTALL = %s\n  JOBS    = %s\n  BUILD   = %s (Runtimes: %s [%s], Assertions: %s, Strip: %s, Shared: %s, DefaultStatic: %s)\n' "$SRC" "$INSTALL" "$JOBS" "$BUILD_TYPE" "$RUNTIMES_BUILD_TYPE" "${RUNTIMES_OPT_LEVEL:--O2}" "$ENABLE_ASSERTIONS" "$STRIP_SYMBOLS" "$ENABLE_SHARED" "$DEFAULT_STATIC_LINK"
printf '  PROJECTS= %s\n  TARGETS = %s\n' "${LLVM_ENABLE_PROJECTS:-clang;lld}" "${LLVM_TARGETS_TO_BUILD:-$LLVM_TARGET_ARCH}"
printf '  VERSIONS= LLVM:%s | torch-mlir:%s | triton:%s | musl:%s | linux-headers:%s\n' "${LLVM_REF:-default}" "${TORCH_MLIR_REF:-default}" "${TRITON_REF:-default}" "${MUSL_REF:-default}" "${LINUX_HEADERS_REF:-default}"
[ -n "${LLVM_EXTRA_CMAKE_ARGS:-}" ] && printf '  CMAKE_EXTRA = %s\n' "$LLVM_EXTRA_CMAKE_ARGS"

# 引入所有步骤模块
# shellcheck disable=SC1091
source "$SRC/scripts/bootstrap.sh"
# shellcheck disable=SC1091
source "$SRC/scripts/fetch.sh"
# shellcheck disable=SC1091
# shellcheck disable=SC1091
# shellcheck disable=SC1091
source "$SRC/scripts/llvm.sh"
# shellcheck disable=SC1091
source "$SRC/scripts/runtimes.sh"
# shellcheck disable=SC1091
source "$SRC/scripts/torch_mlir.sh"
# shellcheck disable=SC1091
source "$SRC/scripts/triton.sh"
# shellcheck disable=SC1091
source "$SRC/scripts/prune.sh"
# shellcheck disable=SC1091
source "$SRC/scripts/verify.sh"
# shellcheck disable=SC1091
source "$SRC/scripts/package.sh"

step_musl_rv32() {
  local saved_t="$TARGET" saved_sysroot="${SYSROOT:-}" saved_br="${BUILD_RUNTIMES:-}"
  TARGET="riscv32-linux-musl"
  SYSROOT="${INSTALL}/sysroot32"
  BUILD_RUNTIMES="$BUILD_DIR/build-runtimes-riscv32"
  unset TARGET_EXTRA_CFLAGS
  init_config
  SYSROOT="${INSTALL}/sysroot32"
  step_musl
  TARGET="$saved_t"
  unset TARGET_EXTRA_CFLAGS
  [ -n "$saved_sysroot" ] && SYSROOT="$saved_sysroot"
  [ -n "$saved_br" ] && BUILD_RUNTIMES="$saved_br"
  init_config
}

step_compiler_rt_rv32() {
  local saved_t="$TARGET" saved_sysroot="${SYSROOT:-}" saved_br="${BUILD_RUNTIMES:-}"
  TARGET="riscv32-linux-musl"
  SYSROOT="${INSTALL}/sysroot32"
  BUILD_RUNTIMES="$BUILD_DIR/build-runtimes-riscv32"
  unset TARGET_EXTRA_CFLAGS
  init_config
  SYSROOT="${INSTALL}/sysroot32"
  step_compiler_rt
  TARGET="$saved_t"
  unset TARGET_EXTRA_CFLAGS
  [ -n "$saved_sysroot" ] && SYSROOT="$saved_sysroot"
  [ -n "$saved_br" ] && BUILD_RUNTIMES="$saved_br"
  init_config
}

step_libcxx_rv32() {
  local saved_t="$TARGET" saved_sysroot="${SYSROOT:-}" saved_br="${BUILD_RUNTIMES:-}"
  TARGET="riscv32-linux-musl"
  SYSROOT="${INSTALL}/sysroot32"
  BUILD_RUNTIMES="$BUILD_DIR/build-runtimes-riscv32"
  unset TARGET_EXTRA_CFLAGS
  init_config
  SYSROOT="${INSTALL}/sysroot32"
  step_libcxx
  TARGET="$saved_t"
  unset TARGET_EXTRA_CFLAGS
  [ -n "$saved_sysroot" ] && SYSROOT="$saved_sysroot"
  [ -n "$saved_br" ] && BUILD_RUNTIMES="$saved_br"
  init_config
}

step_runtimes_rv32() {
  log "构建 RISC-V 32 目标运行库全集 (riscv32-unknown-linux-musl: musl -> compiler-rt -> libc++)"
  local saved_t="$TARGET" saved_sysroot="${SYSROOT:-}" saved_br="${BUILD_RUNTIMES:-}"
  TARGET="riscv32-linux-musl"
  SYSROOT="${INSTALL}/sysroot32"
  BUILD_RUNTIMES="$BUILD_DIR/build-runtimes-riscv32"
  unset TARGET_EXTRA_CFLAGS
  init_config
  SYSROOT="${INSTALL}/sysroot32"
  step_musl
  step_compiler_rt
  step_libcxx
  mark runtimes
  TARGET="$saved_t"
  unset TARGET_EXTRA_CFLAGS
  [ -n "$saved_sysroot" ] && SYSROOT="$saved_sysroot"
  [ -n "$saved_br" ] && BUILD_RUNTIMES="$saved_br"
  init_config
  ok "RISC-V 32 目标运行库全集构建完成"
}

step_verify_rv32() {
  log "验证 RISC-V 32 工具链运行库与冒烟测试"
  local saved_t="$TARGET" saved_sysroot="${SYSROOT:-}" saved_br="${BUILD_RUNTIMES:-}"
  TARGET="riscv32-linux-musl"
  SYSROOT="${INSTALL}/sysroot32"
  BUILD_RUNTIMES="$BUILD_DIR/build-runtimes-riscv32"
  unset TARGET_EXTRA_CFLAGS
  init_config
  SYSROOT="${INSTALL}/sysroot32"
  step_verify
  TARGET="$saved_t"
  unset TARGET_EXTRA_CFLAGS
  [ -n "$saved_sysroot" ] && SYSROOT="$saved_sysroot"
  [ -n "$saved_br" ] && BUILD_RUNTIMES="$saved_br"
  init_config
}

run_step() {
  local step="$1"

  # ─── 隐式前置：任何步骤都依赖引导工具链 ────────────────────────────────
  # bootstrap 负责探测宿主的 cmake / ninja / make / clang(或 gcc) 并软链进
  # $BOOT/bin。缺少它时，`--step llvm` 这类单步执行会直接崩在缺编译器上。
  # step_bootstrap 幂等（is_done bootstrap 会立刻返回），可以放心隐式调用。
  if [ "$step" != "bootstrap" ]; then
    if [ ! -x "$BOOT/bin/clang++" ] || ! is_done bootstrap; then
      unmark bootstrap
      log "引导工具链缺失或不完整，自动先执行 bootstrap"
      step_bootstrap
      step_host_cxx
    fi
  fi

  case "$step" in
    bootstrap)
      step_bootstrap
      step_host_cxx
      ;;
    fetch)
      step_fetch
      ;;
    llvm)
      step_llvm
      ;;
    musl)
      step_musl
      ;;
    builtins|compiler-rt|compiler_rt)
      step_compiler_rt
      ;;
    libcxx|libc++|libunwind)
      step_libcxx
      ;;
    runtimes|runtime)
      step_runtimes
      ;;
    musl-rv32|musl32)
      step_musl_rv32
      ;;
    builtins-rv32|compiler-rt-rv32|compiler_rt-rv32|compiler-rt32)
      step_compiler_rt_rv32
      ;;
    libcxx-rv32|libc++-rv32|libunwind-rv32|libcxx32)
      step_libcxx_rv32
      ;;
    runtimes-rv32|runtimes32|runtime-rv32|runtime32)
      step_runtimes_rv32
      ;;
    verify-rv32|verify32)
      step_verify_rv32
      ;;
    torch-mlir|torch_mlir)
      step_torch_mlir
      ;;
    triton)
      step_triton
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

# 单独步骤执行模式（支持单个或按序指定多个步骤，如 --step musl --step compiler-rt）
if [ ${#SELECTED_STEPS[@]} -gt 0 ]; then
  for step in "${SELECTED_STEPS[@]}"; do
    case "$step" in
      musl)
        unmark musl
        unmark runtimes
        ;;
      compiler-rt|compiler_rt|builtins)
        unmark compiler_rt
        unmark builtins
        unmark runtimes
        ;;
      libcxx|libc++|libunwind)
        unmark libcxx
        unmark libc++
        unmark runtimes
        ;;
      runtimes|runtime)
        unmark runtimes
        unmark musl
        unmark compiler_rt
        unmark builtins
        unmark libcxx
        unmark libc++
        ;;
      musl-rv32|musl32)
        TARGET="riscv32-linux-musl"; init_config
        unmark musl
        unmark runtimes
        ;;
      compiler-rt-rv32|compiler_rt-rv32|builtins-rv32|compiler-rt32)
        TARGET="riscv32-linux-musl"; init_config
        unmark compiler_rt
        unmark builtins
        unmark runtimes
        ;;
      libcxx-rv32|libc++-rv32|libunwind-rv32|libcxx32)
        TARGET="riscv32-linux-musl"; init_config
        unmark libcxx
        unmark libc++
        unmark runtimes
        ;;
      runtimes-rv32|runtimes32|runtime-rv32|runtime32)
        TARGET="riscv32-linux-musl"; init_config
        unmark runtimes
        unmark musl
        unmark compiler_rt
        unmark builtins
        unmark libcxx
        unmark libc++
        ;;
      verify-rv32|verify32)
        TARGET="riscv32-linux-musl"; init_config
        unmark verify
        ;;
      torch-mlir|torch_mlir)
        unmark torch_mlir
        ;;
      triton)
        unmark triton
        ;;
      *)
        unmark "$step"
        ;;
    esac
    log "单独执行步骤: $step"
    run_step "$step"
    ok "步骤 $step 执行完毕"
  done
  exit 0
fi

# 重新构建 LLVM 模式处理
if [ "$REBUILD_LLVM" = 1 ]; then
  unmark llvm
  unmark runtimes
  unmark musl
  unmark compiler_rt
  unmark builtins
  unmark libcxx
  unmark libc++
  unmark prune
  unmark verify
fi

# 标准流水线步骤序列
PIPELINE=(bootstrap fetch llvm runtimes)
if [ "${ENABLE_TORCH_MLIR:-0}" = 1 ] || [ "${CLI_ENABLE_TORCH_MLIR:-0}" = 1 ]; then
  PIPELINE+=(torch-mlir)
fi
if [ "${ENABLE_TRITON:-0}" = 1 ] || [ "${CLI_ENABLE_TRITON:-0}" = 1 ]; then
  PIPELINE+=(triton)
fi
PIPELINE+=(prune verify)
if [ "${CLI_ENABLE_RV32:-0}" = 1 ]; then
  PIPELINE+=(runtimes-rv32 verify-rv32)
fi

if [ "$ONLY_FETCH" = 1 ]; then
  PIPELINE=(bootstrap fetch)
fi

should_run=0
if [ "$START_FROM" = "compiler-rt" ] || [ "$START_FROM" = "compiler_rt" ] || [ "$START_FROM" = "builtins" ] || [ "$START_FROM" = "musl" ] || [ "$START_FROM" = "libc++" ] || [ "$START_FROM" = "libcxx" ]; then
  START_FROM="runtimes"
fi
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
printf '底层交叉工具链路径: %s\n' "$INSTALL"
if [ -d "${INSTALL_AI:-$SRC/install-ai}" ]; then
  printf '统一 AI 编译器路径: %s\n' "${INSTALL_AI:-$SRC/install-ai}"
fi
printf '环境一键激活脚本  : source %s/env.sh\n' "$SRC"
printf '三元组别名调用    : %s/bin/%s-clang hello.c\n' "$INSTALL" "$T"
printf '标准参数调用      : %s/bin/clang --target=%s --sysroot=%s hello.c\n' "$INSTALL" "$T" "$SYSROOT"

BUILD_END_TIME=$(date +%s)
ELAPSED=$((BUILD_END_TIME - BUILD_START_TIME))
printf '总计构建耗时      : %d分 %d秒\n' "$((ELAPSED / 60))" "$((ELAPSED % 60))" 
