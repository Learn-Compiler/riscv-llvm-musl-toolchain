#!/usr/bin/env bash
# ==============================================================================
# scripts/llvm.sh - 配置并构建 LLVM 核心编译器工具链 (clang/lld/llvm-ar)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
init_config

step_llvm() {
  if is_done llvm; then
    ok "LLVM 编译器工具已构建完成，跳过"
    return
  fi
  log "配置并构建 LLVM 核心编译器工具 (clang/lld/llvm-ar 等)"
  mkdir -p "$BUILD"

  # 保证宿主 CXX 参数有效（若未加载则自动探测）
  if [ -z "${HOST_CXX_FLAGS:-}" ] || [ -z "${HOST_LINK_FLAGS:-}" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/bootstrap.sh"
    step_host_cxx
  fi

  local enable_projects="${LLVM_ENABLE_PROJECTS:-clang;lld}"
  local targets_to_build="${LLVM_TARGETS_TO_BUILD:-}"
  if [ -z "$targets_to_build" ]; then
    if [[ ";${enable_projects};" == *";mlir;"* ]] || [ "${ENABLE_MLIR:-0}" = 1 ] || [ "${ENABLE_TORCH_MLIR:-0}" = 1 ]; then
      targets_to_build="${LLVM_TARGET_ARCH};X86"
    else
      targets_to_build="$LLVM_TARGET_ARCH"
    fi
  fi

  local install_toolchain_only="${LLVM_INSTALL_TOOLCHAIN_ONLY:-auto}"
  if [ "$install_toolchain_only" = "auto" ]; then
    if [[ ";${enable_projects};" == *";mlir;"* ]] || [ "${ENABLE_MLIR:-0}" = 1 ] || [ "${ENABLE_TORCH_MLIR:-0}" = 1 ]; then
      install_toolchain_only="Off"
    else
      install_toolchain_only="On"
    fi
  fi

  local extra_cmake_flags=()
  if [ -n "${LLVM_EXTRA_CMAKE_ARGS:-}" ]; then
    read -r -a extra_cmake_flags <<< "${LLVM_EXTRA_CMAKE_ARGS}"
  fi

  local ccache_flag=()
  if [ "${ENABLE_CCACHE:-AUTO}" != "OFF" ] && [ -x "$BOOT/bin/ccache" ]; then
    ccache_flag=("-DLLVM_CCACHE_BUILD=ON")
  fi

  log "配置 LLVM (子项目: $enable_projects, 后端架构: $targets_to_build, ToolchainOnly: $install_toolchain_only)"

  "$BOOT/bin/cmake" -G Ninja -S "$LLVM_DIR/llvm" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DLLVM_OPTIMIZED_TABLEGEN=ON \
    -DCMAKE_INSTALL_PREFIX="$INSTALL" \
    -DCMAKE_C_COMPILER="$BOOT/bin/clang" \
    -DCMAKE_CXX_COMPILER="$BOOT/bin/clang++" \
    -DCMAKE_C_FLAGS="$HOST_CXX_FLAGS" \
    -DCMAKE_CXX_FLAGS="$HOST_CXX_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$HOST_LINK_FLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="$HOST_LINK_FLAGS" \
    -DCMAKE_MODULE_LINKER_FLAGS="$HOST_LINK_FLAGS" \
    -DLLVM_ENABLE_PIC=ON \
    -DLLVM_TARGETS_TO_BUILD="$targets_to_build" \
    -DLLVM_ENABLE_PROJECTS="$enable_projects" \
    -DLLVM_ENABLE_RUNTIMES="" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="$T" \
    -DLLVM_INSTALL_TOOLCHAIN_ONLY="$install_toolchain_only" \
    -DLLVM_INSTALL_UTILS=ON \
    -DLLVM_ENABLE_ASSERTIONS="$ENABLE_ASSERTIONS" \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DDEFAULT_SYSROOT=../sysroot \
    -DCLANG_DEFAULT_LINKER=lld \
    -DCLANG_DEFAULT_RTLIB=compiler-rt \
    -DCLANG_DEFAULT_UNWINDLIB=libunwind \
    -DCLANG_DEFAULT_CXX_STDLIB=libc++ \
    -DLLVM_PARALLEL_LINK_JOBS=1 \
    "${ccache_flag[@]}" \
    "${extra_cmake_flags[@]}"

  log "编译 LLVM (-j$JOBS)"
  "$BOOT/bin/ninja" -C "$BUILD" -j"$JOBS"

  log "安装 LLVM 编译器工具到 $INSTALL"
  "$BOOT/bin/ninja" -C "$BUILD" install

  mark llvm
  ok "LLVM 编译器工具构建并安装完成"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_llvm
fi
