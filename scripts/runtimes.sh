#!/usr/bin/env bash
# ==============================================================================
# scripts/runtimes.sh - 编译目标全套运行时 (libc.a / builtins / crt / libunwind / libc++)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
init_config

step_runtimes() {
  if is_done runtimes; then
    ok "目标全套运行库已构建完成，跳过"
    return
  fi
  log "构建目标运行库全集 (libc.a / builtins / crtbegin / libunwind / libc++)"

  local target_clang="$INSTALL/bin/clang"
  local target_clangxx="$INSTALL/bin/clang++"
  local target_ar="$INSTALL/bin/llvm-ar"
  local target_nm="$INSTALL/bin/llvm-nm"
  local target_ranlib="$INSTALL/bin/llvm-ranlib"
  local target_strip="$INSTALL/bin/llvm-strip"
  local target_objcopy="$INSTALL/bin/llvm-objcopy"

  [ -x "$target_clang" ] || die "未找到编译器 $target_clang，请先完成 ./build.sh --step llvm"

  # ─── 1. 准备 Sysroot 基础环境与 Linux 内核头文件 ───────────────────
  log "准备 Linux 内核头文件到 Sysroot"
  mkdir -p "$SYSROOT/usr/include" "$SYSROOT/usr/lib" "$SYSROOT/lib"
  local hdr_dir
  hdr_dir="$(get_linux_headers_include_dir)"
  [ -d "$hdr_dir" ] || die "缺少 Linux 内核头文件目录: $hdr_dir"
  cp -rL "$hdr_dir/." "$SYSROOT/usr/include/"

  # ─── 2. 编译目标 C 运行库 Musl (libc.a) ───────────────────────────
  log "使用已构建的 LLVM 编译目标 C 运行库 Musl (libc.a)"

  cd "$MUSL_DIR"
  make distclean >/dev/null 2>&1 || true

  local musl_shared_flags=()
  if [ "${ENABLE_SHARED:-OFF}" = "ON" ]; then
    musl_shared_flags=("--enable-shared")
  else
    musl_shared_flags=("--disable-shared")
  fi

  local musl_extra_flags=()
  if [ -n "${MUSL_EXTRA_ARGS:-}" ]; then
    read -r -a musl_extra_flags <<< "${MUSL_EXTRA_ARGS}"
  fi

  CC="$target_clang --target=$T -fuse-ld=lld" \
  AR="$target_ar" \
  RANLIB="$target_ranlib" \
  ./configure \
      --target="$MUSL_TARGET" \
      --prefix=/usr \
      --syslibdir=/lib \
      --disable-gcc-wrapper \
      --enable-static \
      "${musl_shared_flags[@]}" \
      "${musl_extra_flags[@]}"

  make -j"$JOBS" AR="$target_ar" RANLIB="$target_ranlib"
  make DESTDIR="$SYSROOT" install

  if [ "${ENABLE_SHARED:-OFF}" = "ON" ]; then
    ln -sf ../usr/lib/libc.so "$SYSROOT/lib/$LD_MUSL_SO"
  fi
  cp -rL "$hdr_dir/." "$SYSROOT/usr/include/"
  ok "目标 C 运行库 (libc.a) 编译并安装就绪"

  # ─── 3. 构建 LLVM 目标运行库 (builtins / crt / libunwind / libc++) ───
  log "编译 LLVM 目标运行库 (compiler-rt crt / builtins / libunwind / libc++ / libc++abi)"
  local RUNTIMES_BUILD="${BUILD_RUNTIMES:-$SRC/build-runtimes}"
  mkdir -p "$RUNTIMES_BUILD"
  rm -rf "$RUNTIMES_BUILD/include/c++/v1" "$INSTALL/include/c++/v1"

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
    -DLLVM_ENABLE_RUNTIMES="${LLVM_ENABLE_RUNTIMES:-compiler-rt;libunwind;libcxx;libcxxabi}" \
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

  "$BOOT/bin/ninja" -C "$RUNTIMES_BUILD" -j"$JOBS"
  "$BOOT/bin/ninja" -C "$RUNTIMES_BUILD" install

  # ─── 4. 部署 compiler-rt crt 与 builtins ───────────────────────────
  log "部署 compiler-rt crt (crtbegin/crtend) 与 builtins"
  local clang_ver
  clang_ver=$("$target_clang" -dumpversion 2>/dev/null | cut -d. -f1 || echo "23")
  local inst_res="$INSTALL/lib/clang/$clang_ver/lib/$T"
  mkdir -p "$inst_res"

  local builtin_name="${RT_BUILTIN_NAME:-libclang_rt.builtins-riscv64.a}"
  for b in "$RUNTIMES_BUILD/compiler-rt/lib/linux/$builtin_name" \
           "$INSTALL/lib/linux/$builtin_name" \
           "$INSTALL/lib/$T/libclang_rt.builtins.a"; do
    if [ -f "$b" ]; then
      cp -a "$b" "$inst_res/libclang_rt.builtins.a"
      cp -a "$b" "$inst_res/$builtin_name"
      cp -a "$b" "$SYSROOT/usr/lib/libclang_rt.builtins.a"
      break
    fi
  done

  local crt_begin="${RT_CRT_BEGIN:-clang_rt.crtbegin-riscv64.o}"
  local crt_end="${RT_CRT_END:-clang_rt.crtend-riscv64.o}"
  for cdir in "$RUNTIMES_BUILD/compiler-rt/lib/linux" "$INSTALL/lib/linux"; do
    if [ -f "$cdir/$crt_begin" ]; then
      cp -a "$cdir/$crt_begin" "$inst_res/clang_rt.crtbegin.o"
      cp -a "$cdir/$crt_end"   "$inst_res/clang_rt.crtend.o"
      cp -a "$cdir/$crt_begin" "$inst_res/crtbegin.o"
      cp -a "$cdir/$crt_end"   "$inst_res/crtend.o"
      cp -a "$cdir/$crt_begin" "$SYSROOT/usr/lib/crtbegin.o" 2>/dev/null || true
      cp -a "$cdir/$crt_end"   "$SYSROOT/usr/lib/crtend.o" 2>/dev/null || true
      break
    fi
  done

  # ─── 5. 合并 libc++abi.a 到静态 libc++.a ────────────────────────────
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

  # ─── 6. C++ 运行库与 libunwind 同步至 sysroot ─────────────────────
  mkdir -p "$SYSROOT/usr/lib" "$SYSROOT/lib"
  if [ -d "$inst_rtdir" ]; then
    cp -a "$inst_rtdir"/libc++*   "$SYSROOT/usr/lib/" 2>/dev/null || true
    cp -a "$inst_rtdir"/libunwind* "$SYSROOT/usr/lib/" 2>/dev/null || true
    cp -a "$inst_rtdir"/libc++*   "$SYSROOT/lib/" 2>/dev/null || true
    cp -a "$inst_rtdir"/libunwind* "$SYSROOT/lib/" 2>/dev/null || true
  fi

  if [ "${ENABLE_SHARED:-OFF}" = "OFF" ]; then
    rm -f "$SYSROOT"/usr/lib/libc++.so* "$SYSROOT"/usr/lib/libc++abi.so* "$SYSROOT"/usr/lib/libunwind.so* "$SYSROOT"/usr/lib/libc.so* "$SYSROOT"/usr/lib/"$LD_MUSL_SO" 2>/dev/null || true
    rm -f "$SYSROOT"/lib/libc++.so* "$SYSROOT"/lib/libc++abi.so* "$SYSROOT"/lib/libunwind.so* "$SYSROOT"/lib/libc.so* "$SYSROOT"/lib/"$LD_MUSL_SO" 2>/dev/null || true
  fi

  mark musl
  mark builtins
  mark runtimes
  ok "全部目标运行库 (libc.a / builtins / crtbegin / libunwind / libc++) 编译并安装完成"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_runtimes
fi
