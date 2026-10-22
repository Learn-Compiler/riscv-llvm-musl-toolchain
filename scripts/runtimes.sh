#!/usr/bin/env bash
# ==============================================================================
# scripts/runtimes.sh - 使用编译好的 Clang 独立构建目标运行库 (compiler-rt crt / libunwind / libc++)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
init_config

step_runtimes() {
  if is_done runtimes; then
    ok "C++ 运行库 (libc++/libunwind) 已构建完成，跳过"
    return
  fi
  log "配置并构建目标运行库 (compiler-rt crt / libunwind / libc++ / libc++abi)"

  local target_clang="$INSTALL/bin/clang"
  local target_clangxx="$INSTALL/bin/clang++"
  local target_ar="$INSTALL/bin/llvm-ar"
  local target_nm="$INSTALL/bin/llvm-nm"
  local target_ranlib="$INSTALL/bin/llvm-ranlib"

  [ -x "$target_clang" ] || die "未找到编译器 $target_clang，请先完成 ./build.sh --step llvm"
  [ -f "$SYSROOT/usr/lib/libc.a" ] || die "缺少 sysroot libc.a，请先完成 ./build.sh --step musl"

  local RUNTIMES_BUILD="${BUILD_RUNTIMES:-$SRC/build-runtimes}"
  mkdir -p "$RUNTIMES_BUILD"

  # 清理可能由旧版本 LLVM 遗留在 libcxx 中的陈旧头文件与断言冲突
  rm -rf "$RUNTIMES_BUILD/include/c++/v1" "$INSTALL/include/c++/v1"

  log "配置目标运行库 CMake"
  "$BOOT/bin/cmake" -G Ninja \
    -S "$LLVM_DIR/runtimes" \
    -B "$RUNTIMES_BUILD" \
    -DCMAKE_BUILD_TYPE="${RUNTIMES_BUILD_TYPE:-Release}" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL" \
    -DCMAKE_C_COMPILER="$target_clang" \
    -DCMAKE_CXX_COMPILER="$target_clangxx" \
    -DCMAKE_ASM_COMPILER="$target_clang" \
    -DCMAKE_AR="$target_ar" \
    -DCMAKE_NM="$target_nm" \
    -DCMAKE_RANLIB="$target_ranlib" \
    -DLLVM_ENABLE_RUNTIMES="compiler-rt;libunwind;libcxx;libcxxabi" \
    -DCMAKE_C_COMPILER_TARGET="$T" \
    -DCMAKE_CXX_COMPILER_TARGET="$T" \
    -DCMAKE_ASM_COMPILER_TARGET="$T" \
    -DCMAKE_SYSROOT="$SYSROOT" \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    -DCOMPILER_RT_BUILD_CRT=ON \
    -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
    -DCOMPILER_RT_BUILD_XRAY=OFF \
    -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
    -DCOMPILER_RT_BUILD_PROFILE=OFF \
    -DCOMPILER_RT_BUILD_MEMPROF=OFF \
    -DCOMPILER_RT_BUILD_ORC=OFF \
    -DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON \
    -DCOMPILER_RT_USE_LLVM_UNWINDER=ON \
    -DCOMPILER_RT_INCLUDE_TESTS=OFF \
    -DLIBUNWIND_INCLUDE_TESTS=OFF \
    -DLIBCXX_INCLUDE_TESTS=OFF \
    -DLIBCXXABI_INCLUDE_TESTS=OFF \
    -DLIBCXX_HAS_MUSL_LIBC=ON \
    -DLIBCXX_ENABLE_SHARED=${ENABLE_SHARED:-OFF} \
    -DLIBCXX_ENABLE_STATIC=ON \
    -DLIBCXX_ENABLE_ABI_LINKER_SCRIPT=${ENABLE_SHARED:-OFF} \
    -DLIBCXXABI_ENABLE_SHARED=${ENABLE_SHARED:-OFF} \
    -DLIBCXXABI_ENABLE_STATIC=ON \
    -DLIBUNWIND_ENABLE_SHARED=${ENABLE_SHARED:-OFF} \
    -DLIBUNWIND_ENABLE_STATIC=ON \
    -DLIBCXXABI_USE_COMPILER_RT=ON \
    -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
    -DLIBUNWIND_USE_COMPILER_RT=ON \
    -DLLVM_PARALLEL_LINK_JOBS=1

  log "编译目标运行库 (-j$JOBS)"
  "$BOOT/bin/ninja" -C "$RUNTIMES_BUILD" -j"$JOBS"

  log "安装目标运行库到 $INSTALL"
  "$BOOT/bin/ninja" -C "$RUNTIMES_BUILD" install

  # 将 libc++abi.a 合并进静态 libc++.a，解决静态链接只传 -lc++ 导致的 ABI 符号未定义
  local inst_rtdir="$INSTALL/lib/$T"
  [ -d "$inst_rtdir" ] || inst_rtdir="$INSTALL/lib"
  if [ -f "$inst_rtdir/libc++.a" ] && [ -f "$inst_rtdir/libc++abi.a" ]; then
    log "合并 libc++abi.a 到静态 libc++.a"
    local mri_script="$RUNTIMES_BUILD/merge_libcxx.mri"
    cat > "$mri_script" <<MRI_EOF
CREATE $inst_rtdir/libc++_merged.a
ADDLIB $inst_rtdir/libc++.a
ADDLIB $inst_rtdir/libc++abi.a
SAVE
END
MRI_EOF
    "$INSTALL/bin/llvm-ar" -M < "$mri_script"
    mv -f "$inst_rtdir/libc++_merged.a" "$inst_rtdir/libc++.a"
    rm -f "$mri_script"
  fi

  # C++ 运行库补进 sysroot
  mkdir -p "$SYSROOT/usr/lib" "$SYSROOT/lib"
  if [ -d "$inst_rtdir" ]; then
    cp -a "$inst_rtdir"/libc++*   "$SYSROOT/usr/lib/" 2>/dev/null || true
    cp -a "$inst_rtdir"/libunwind* "$SYSROOT/usr/lib/" 2>/dev/null || true
    cp -a "$inst_rtdir"/libc++*   "$SYSROOT/lib/" 2>/dev/null || true
    cp -a "$inst_rtdir"/libunwind* "$SYSROOT/lib/" 2>/dev/null || true
  fi

  # 若为纯静态模式，清理可能残留的目标端共享库
  if [ "${ENABLE_SHARED:-OFF}" = "OFF" ]; then
    rm -f "$SYSROOT"/usr/lib/libc++.so* "$SYSROOT"/usr/lib/libc++abi.so* "$SYSROOT"/usr/lib/libunwind.so* "$SYSROOT"/usr/lib/libc.so* "$SYSROOT"/usr/lib/"$LD_MUSL_SO" 2>/dev/null || true
    rm -f "$SYSROOT"/lib/libc++.so* "$SYSROOT"/lib/libc++abi.so* "$SYSROOT"/lib/libunwind.so* "$SYSROOT"/lib/libc.so* "$SYSROOT"/lib/"$LD_MUSL_SO" 2>/dev/null || true
  fi

  mark runtimes
  ok "目标运行库构建并安装完成"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_runtimes
fi
