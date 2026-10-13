#!/usr/bin/env bash
# ==============================================================================
# scripts/llvm.sh - 配置并构建 LLVM 工具链及运行时 (compiler-rt/libc++/libunwind)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
init_config

step_llvm() {
  if is_done llvm; then
    ok "LLVM + runtimes 已构建完成，跳过"
    return
  fi
  log "4/5 配置 LLVM + runtimes"
  mkdir -p "$BUILD"
  ln -sfn "$SYSROOT" "$BUILD/sysroot"     # 构建期 clang 从 ../sysroot 找 sysroot

  # 保证宿主 CXX 参数有效（若未加载则自动探测）
  if [ -z "${HOST_CXX_FLAGS:-}" ] || [ -z "${HOST_LINK_FLAGS:-}" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/bootstrap.sh"
    step_host_cxx
  fi

  local enable_projects="${LLVM_ENABLE_PROJECTS:-clang;lld}"
  local enable_runtimes="${LLVM_ENABLE_RUNTIMES:-compiler-rt;libcxx;libcxxabi;libunwind}"

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

  log "4/5 配置 LLVM + runtimes (子项目: $enable_projects, 后端架构: $targets_to_build, ToolchainOnly: $install_toolchain_only)"

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
    -DLLVM_ENABLE_RUNTIMES="$enable_runtimes" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="$T" \
    -DLLVM_RUNTIME_TARGETS="$T" \
    -DLLVM_INSTALL_TOOLCHAIN_ONLY="$install_toolchain_only" \
    -DLLVM_INSTALL_UTILS=ON \
    -DLLVM_ENABLE_ASSERTIONS="$ENABLE_ASSERTIONS" \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DDEFAULT_SYSROOT=../sysroot \
    -DCLANG_DEFAULT_LINKER=lld \
    -DCLANG_DEFAULT_RTLIB=compiler-rt \
    -DCLANG_DEFAULT_UNWINDLIB=libunwind \
    -DCLANG_DEFAULT_CXX_STDLIB=libc++ \
    -DCOMPILER_RT_BUILD_CRT:BOOL=ON \
    -DRUNTIMES_${T}_COMPILER_RT_BUILD_CRT:BOOL=ON \
    -DRUNTIMES_${T}_LIBCXX_HAS_MUSL_LIBC=On \
    -DRUNTIMES_${T}_COMPILER_RT_BUILD_SANITIZERS=Off \
    -DRUNTIMES_${T}_COMPILER_RT_BUILD_XRAY=OFF \
    -DRUNTIMES_${T}_COMPILER_RT_BUILD_LIBFUZZER=OFF \
    -DRUNTIMES_${T}_COMPILER_RT_BUILD_PROFILE=OFF \
    -DRUNTIMES_${T}_COMPILER_RT_BUILD_MEMPROF=OFF \
    -DRUNTIMES_${T}_COMPILER_RT_BUILD_ORC=OFF \
    -DRUNTIMES_${T}_COMPILER_RT_USE_BUILTINS_LIBRARY=ON \
    -DRUNTIMES_${T}_COMPILER_RT_USE_LLVM_UNWINDER=ON \
    -DRUNTIMES_${T}_LLVM_INCLUDE_TESTS=OFF \
    -DRUNTIMES_${T}_COMPILER_RT_INCLUDE_TESTS=OFF \
    -DRUNTIMES_${T}_LIBUNWIND_INCLUDE_TESTS=OFF \
    -DRUNTIMES_${T}_LIBCXX_INCLUDE_TESTS=OFF \
    -DRUNTIMES_${T}_LIBCXXABI_INCLUDE_TESTS=OFF \
    -DRUNTIMES_${T}_CMAKE_BUILD_TYPE="${RUNTIMES_BUILD_TYPE:-Release}" \
    -DRUNTIMES_${T}_LIBUNWIND_USE_COMPILER_RT=ON \
    -DRUNTIMES_${T}_LIBCXXABI_USE_COMPILER_RT=ON \
    -DRUNTIMES_${T}_LIBCXXABI_USE_LLVM_UNWINDER=ON \
    -DRUNTIMES_${T}_LIBCXX_ENABLE_SHARED=${ENABLE_SHARED:-OFF} \
    -DRUNTIMES_${T}_LIBCXX_ENABLE_STATIC=ON \
    -DRUNTIMES_${T}_LIBCXX_ENABLE_ABI_LINKER_SCRIPT=${ENABLE_SHARED:-OFF} \
    -DRUNTIMES_${T}_LIBCXXABI_ENABLE_SHARED=${ENABLE_SHARED:-OFF} \
    -DRUNTIMES_${T}_LIBCXXABI_ENABLE_STATIC=ON \
    -DRUNTIMES_${T}_LIBUNWIND_ENABLE_SHARED=${ENABLE_SHARED:-OFF} \
    -DRUNTIMES_${T}_LIBUNWIND_ENABLE_STATIC=ON \
    -DRUNTIMES_${T}_CMAKE_C_FLAGS="--sysroot=$SYSROOT" \
    -DRUNTIMES_${T}_CMAKE_CXX_FLAGS="--sysroot=$SYSROOT" \
    -DRUNTIMES_${T}_CMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld" \
    -DRUNTIMES_${T}_CMAKE_SHARED_LINKER_FLAGS="-fuse-ld=lld" \
    -DRUNTIMES_${T}_CMAKE_MODULE_LINKER_FLAGS="-fuse-ld=lld" \
    -DLLVM_PARALLEL_LINK_JOBS=1 \
    "${extra_cmake_flags[@]}"

  grep -qi 'COMPILER_RT_BUILD_CRT.*ON' "$BUILD/CMakeCache.txt" \
    || die "COMPILER_RT_BUILD_CRT 未生效，检查上面的 cmake 参数"
  ok "cmake 配置完成（COMPILER_RT_BUILD_CRT=ON 已确认）"

  log "4/5 编译（-j$JOBS，预计 30-60 分钟）"
  "$BOOT/bin/ninja" -C "$BUILD" -j"$JOBS"

  log "4/5 安装"
  "$BOOT/bin/ninja" -C "$BUILD" install

  # C++ 运行库补进 sysroot
  cp -a "$BUILD"/lib/"$T"/libc++*   "$SYSROOT/lib/" 2>/dev/null || true
  cp -a "$BUILD"/lib/"$T"/libunwind* "$SYSROOT/lib/" 2>/dev/null || true

  # 若为纯静态模式，清理可能残留的目标端共享库
  if [ "${ENABLE_SHARED:-OFF}" = "OFF" ]; then
    rm -f "$SYSROOT"/lib/libc++.so* "$SYSROOT"/lib/libc++abi.so* "$SYSROOT"/lib/libunwind.so* "$SYSROOT"/lib/libc.so* "$SYSROOT"/lib/"$LD_MUSL_SO" 2>/dev/null || true
  fi
  mark llvm
  ok "安装完成"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_llvm
fi
