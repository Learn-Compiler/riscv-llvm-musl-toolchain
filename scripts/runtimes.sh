#!/usr/bin/env bash
# ==============================================================================
# scripts/runtimes.sh - 目标端全套运行时分步与整合构建
# ==============================================================================
# 包含三大独立子阶段：
#   1. step_musl        - 准备 Linux 头文件与编译目标 C 运行库 Musl (libc.a)
#   2. step_compiler_rt - 编译目标编译器基础函数库与启动对象 (builtins / crt)
#   3. step_libcxx      - 编译目标 C++ 运行时 (libunwind / libc++ / libc++abi)
#   4. step_runtimes    - 编排上述全套运行库构建并完成 Sysroot 同步
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
init_config

# 获取目标交叉编译工具变量
get_target_tools() {
  target_clang="$INSTALL/bin/clang"
  target_clangxx="$INSTALL/bin/clang++"
  target_ar="$INSTALL/bin/llvm-ar"
  target_nm="$INSTALL/bin/llvm-nm"
  target_ranlib="$INSTALL/bin/llvm-ranlib"
  target_strip="$INSTALL/bin/llvm-strip"
  target_objcopy="$INSTALL/bin/llvm-objcopy"
  [ -x "$target_clang" ] || die "未找到编译器 $target_clang，请先完成 ./build.sh --step llvm"
}

# 确保 build-runtimes CMake 配置就绪
ensure_runtimes_configured() {
  local RUNTIMES_BUILD="${BUILD_RUNTIMES:-$SRC/build-runtimes}"
  local opt_level="${RUNTIMES_OPT_LEVEL:-default}"
  mkdir -p "$RUNTIMES_BUILD"
  local target_cflags="${TARGET_EXTRA_CFLAGS:-}"
  local cfg_stamp="$RUNTIMES_BUILD/.configured_state"
  local current_cfg_state="${TARGET}|${T}|${SYSROOT}|${opt_level}|${target_cflags}"
  if [ -f "$RUNTIMES_BUILD/build.ninja" ] && [ -f "$cfg_stamp" ] && [ "$(cat "$cfg_stamp" 2>/dev/null)" = "$current_cfg_state" ]; then
    return 0
  fi
  rm -f "$RUNTIMES_BUILD/build.ninja" "$RUNTIMES_BUILD/CMakeCache.txt"
  echo "$current_cfg_state" > "$cfg_stamp"

  log "配置 LLVM 目标运行库 CMake (compiler-rt / libunwind / libcxx / libcxxabi) [Target: $T, Sysroot: $SYSROOT, 优化级别: $opt_level]"
  get_target_tools
  rm -rf "$RUNTIMES_BUILD/include/c++/v1" "$INSTALL/include/c++/v1"

  local ccache_flag=()
  if [ "${ENABLE_CCACHE:-AUTO}" != "OFF" ] && [ -x "$BOOT/bin/ccache" ]; then
    ccache_flag=("-DLLVM_CCACHE_BUILD=ON")
  fi

  local target_cflags="${TARGET_EXTRA_CFLAGS:-}"
  local opt_flags=()
  if [ -n "${RUNTIMES_OPT_LEVEL:-}" ]; then
    opt_flags=(
      "-DCMAKE_C_FLAGS_RELEASE=${RUNTIMES_OPT_LEVEL} -DNDEBUG"
      "-DCMAKE_CXX_FLAGS_RELEASE=${RUNTIMES_OPT_LEVEL} -DNDEBUG"
      "-DCMAKE_ASM_FLAGS_RELEASE=${RUNTIMES_OPT_LEVEL}"
      "-DCMAKE_C_FLAGS_RELWITHDEBINFO=${RUNTIMES_OPT_LEVEL} -g -DNDEBUG"
      "-DCMAKE_CXX_FLAGS_RELWITHDEBINFO=${RUNTIMES_OPT_LEVEL} -g -DNDEBUG"
    )
  fi

  "$BOOT/bin/cmake" -G Ninja \
    -S "$LLVM_DIR/runtimes" \
    -B "$RUNTIMES_BUILD" \
    -DCMAKE_BUILD_TYPE="${RUNTIMES_BUILD_TYPE:-Release}" \
    "${opt_flags[@]}" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL" \
    -DCMAKE_C_COMPILER="$target_clang" \
    -DCMAKE_CXX_COMPILER="$target_clangxx" \
    -DCMAKE_ASM_COMPILER="$target_clang" \
    -DCMAKE_AR="$target_ar" \
    -DCMAKE_NM="$target_nm" \
    -DCMAKE_RANLIB="$target_ranlib" \
    -DCMAKE_C_FLAGS="$target_cflags" \
    -DCMAKE_CXX_FLAGS="$target_cflags" \
    -DCMAKE_ASM_FLAGS="$target_cflags" \
    -DLLVM_ENABLE_RUNTIMES="${LLVM_ENABLE_RUNTIMES:-compiler-rt;libunwind;libcxx;libcxxabi}" \
    -DCMAKE_C_COMPILER_TARGET="$T" \
    -DCMAKE_CXX_COMPILER_TARGET="$T" \
    -DCMAKE_ASM_COMPILER_TARGET="$T" \
    -DCMAKE_SYSROOT="$SYSROOT" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
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
    -DLLVM_PARALLEL_LINK_JOBS=1 \
    "${ccache_flag[@]}"
}

# 1. 独立构建 Musl C 运行库
step_musl() {
  if is_done musl; then
    ok "目标 C 运行库 (Musl) 已就绪，跳过"
    return
  fi
  get_target_tools
  log "准备 Linux 内核头文件到 Sysroot"
  mkdir -p "$SYSROOT/usr/include" "$SYSROOT/usr/lib" "$SYSROOT/lib"
  local hdr_dir
  hdr_dir="$(get_linux_headers_include_dir)"
  [ -d "$hdr_dir" ] || die "缺少 Linux 内核头文件目录: $hdr_dir"
  cp -rL "$hdr_dir/." "$SYSROOT/usr/include/"

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

  local target_cflags="${TARGET_EXTRA_CFLAGS:-}"
  local musl_cflags_arg=()
  if [ -n "${RUNTIMES_OPT_LEVEL:-}" ]; then
    musl_cflags_arg=("CFLAGS=${RUNTIMES_OPT_LEVEL} ${target_cflags}")
  elif [ -n "${target_cflags:-}" ]; then
    musl_cflags_arg=("CFLAGS=${target_cflags}")
  fi

  CC="$target_clang --target=$T $target_cflags -fuse-ld=lld" \
  AR="$target_ar" \
  RANLIB="$target_ranlib" \
  ./configure \
      --target="$MUSL_TARGET" \
      --prefix=/usr \
      --syslibdir=/lib \
      --disable-gcc-wrapper \
      --enable-static \
      "${musl_shared_flags[@]}" \
      "${musl_extra_flags[@]}" \
      "${musl_cflags_arg[@]}"

  make -j"$JOBS" AR="$target_ar" RANLIB="$target_ranlib"
  make DESTDIR="$SYSROOT" install

  if [ "${ENABLE_SHARED:-OFF}" = "ON" ]; then
    ln -sf ../usr/lib/libc.so "$SYSROOT/lib/$LD_MUSL_SO"
  fi
  cp -rL "$hdr_dir/." "$SYSROOT/usr/include/"

  if [ "$(basename "$SYSROOT")" = "sysroot32" ]; then
    ln -sfn sysroot32 "$INSTALL/sysroot-riscv32"
  fi

  mark musl
  ok "目标 C 运行库 (libc.a) 编译并安装就绪"
}

# 2. 独立构建 compiler-rt (builtins 与 crt)
step_compiler_rt() {
  if is_done compiler_rt; then
    ok "compiler-rt (builtins/crt) 已就绪，跳过"
    return
  fi
  step_musl
  get_target_tools
  ensure_runtimes_configured

  local RUNTIMES_BUILD="${BUILD_RUNTIMES:-$SRC/build-runtimes}"
  log "编译并安装 compiler-rt 目标库 (builtins / crt)"
  "$BOOT/bin/ninja" -C "$RUNTIMES_BUILD" -j"$JOBS" install-compiler-rt

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
      cp -a "$b" "$SYSROOT/lib/libclang_rt.builtins.a"
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
      cp -a "$cdir/$crt_begin" "$inst_res/crtbeginT.o"
      cp -a "$cdir/$crt_begin" "$inst_res/crtbeginS.o"
      cp -a "$cdir/$crt_end"   "$inst_res/crtendS.o"
      cp -a "$cdir/$crt_begin" "$SYSROOT/usr/lib/crtbegin.o" 2>/dev/null || true
      cp -a "$cdir/$crt_end"   "$SYSROOT/usr/lib/crtend.o" 2>/dev/null || true
      cp -a "$cdir/$crt_begin" "$SYSROOT/usr/lib/crtbeginT.o" 2>/dev/null || true
      cp -a "$cdir/$crt_begin" "$SYSROOT/usr/lib/crtbeginS.o" 2>/dev/null || true
      cp -a "$cdir/$crt_end"   "$SYSROOT/usr/lib/crtendS.o" 2>/dev/null || true
      break
    fi
  done

  mark compiler_rt
  mark builtins
  ok "compiler-rt builtins 与 crt 部署完成"
}

# 3. 独立构建 C++ 运行库 (libunwind / libc++ / libc++abi)
step_libcxx() {
  if is_done libcxx; then
    ok "C++ 运行库 (libc++ / libunwind) 已就绪，跳过"
    return
  fi
  step_compiler_rt
  get_target_tools
  ensure_runtimes_configured

  local RUNTIMES_BUILD="${BUILD_RUNTIMES:-$SRC/build-runtimes}"
  log "编译并安装 C++ 目标运行库 (libunwind / libc++ / libc++abi)"
  "$BOOT/bin/ninja" -C "$RUNTIMES_BUILD" -j"$JOBS" install-cxx install-cxxabi install-unwind

  local inst_rtdir="$INSTALL/lib/$T"
  mkdir -p "$inst_rtdir" "$SYSROOT/usr/lib" "$SYSROOT/lib"

  local src_libcxx="$RUNTIMES_BUILD/lib/libc++.a"
  local src_libcxxabi="$RUNTIMES_BUILD/lib/libc++abi.a"
  local src_unwind="$RUNTIMES_BUILD/lib/libunwind.a"
  [ -f "$src_libcxx" ] || src_libcxx="$INSTALL/lib/libc++.a"
  [ -f "$src_libcxxabi" ] || src_libcxxabi="$INSTALL/lib/libc++abi.a"
  [ -f "$src_unwind" ] || src_unwind="$INSTALL/lib/libunwind.a"

  if [ -f "$src_libcxx" ] && [ -f "$src_libcxxabi" ]; then
    log "合并 libc++abi.a 到静态 libc++.a"
    local mri_script="$RUNTIMES_BUILD/merge_libcxx.mri"
    cat > "$mri_script" <<MRI_EOF
CREATE $SYSROOT/usr/lib/libc++.a
ADDLIB $src_libcxx
ADDLIB $src_libcxxabi
SAVE
END
MRI_EOF
    "$INSTALL/bin/llvm-ar" -M < "$mri_script"
    rm -f "$mri_script"
    cp -a "$SYSROOT/usr/lib/libc++.a" "$SYSROOT/lib/libc++.a"
    cp -a "$SYSROOT/usr/lib/libc++.a" "$inst_rtdir/libc++.a"
  elif [ -f "$src_libcxx" ]; then
    cp -a "$src_libcxx" "$SYSROOT/usr/lib/libc++.a"
    cp -a "$src_libcxx" "$SYSROOT/lib/libc++.a"
    cp -a "$src_libcxx" "$inst_rtdir/libc++.a"
  fi

  if [ -f "$src_unwind" ]; then
    cp -a "$src_unwind" "$SYSROOT/usr/lib/libunwind.a"
    cp -a "$src_unwind" "$SYSROOT/lib/libunwind.a"
    cp -a "$src_unwind" "$inst_rtdir/libunwind.a"
  fi

  if [ "${ENABLE_SHARED:-OFF}" = "OFF" ]; then
    rm -f "$SYSROOT"/usr/lib/libc++.so* "$SYSROOT"/usr/lib/libc++abi.so* "$SYSROOT"/usr/lib/libunwind.so* "$SYSROOT"/usr/lib/libc.so* "$SYSROOT"/usr/lib/"$LD_MUSL_SO" 2>/dev/null || true
    rm -f "$SYSROOT"/lib/libc++.so* "$SYSROOT"/lib/libc++abi.so* "$SYSROOT"/lib/libunwind.so* "$SYSROOT"/lib/libc.so* "$SYSROOT"/lib/"$LD_MUSL_SO" 2>/dev/null || true
  fi

  # 若构建的是 riscv32 模块，自动生成 riscv32 专用配置与三元组软链接
  if [ "$TARGET" = "riscv32-linux-musl" ]; then
    log "生成 RISC-V 32 专用配置 ($INSTALL/bin/riscv32-unknown-linux-musl.cfg) 与编译器入口软链接"
    local sysroot_rel
    sysroot_rel="$(basename "$SYSROOT")"
    cat > "$INSTALL/bin/riscv32-unknown-linux-musl.cfg" <<CFG_EOF
--target=riscv32-unknown-linux-musl
--sysroot=<CFGDIR>/../${sysroot_rel}
-march=rv32gc
-mabi=ilp32d
-fuse-ld=lld
-rtlib=compiler-rt
-unwindlib=libunwind
-stdlib=libc++
CFG_EOF
    if [ "${DEFAULT_STATIC_LINK:-ON}" = "ON" ]; then
      echo "-static" >> "$INSTALL/bin/riscv32-unknown-linux-musl.cfg"
    fi
    ln -sfn riscv32-unknown-linux-musl.cfg "$INSTALL/bin/riscv32.cfg"
    ln -sfn riscv32-unknown-linux-musl.cfg "$INSTALL/bin/riscv32-linux-musl.cfg"
    ln -sfn clang "$INSTALL/bin/riscv32-unknown-linux-musl-clang"
    ln -sfn clang++ "$INSTALL/bin/riscv32-unknown-linux-musl-clang++"
    ln -sfn clang "$INSTALL/bin/riscv32-linux-musl-clang"
    ln -sfn clang++ "$INSTALL/bin/riscv32-linux-musl-clang++"
  fi

  mark libcxx
  mark libc++
  ok "C++ 运行库与 libunwind 部署完成"
}

# 4. 目标全套运行时统一构建 (用于流水线与完整构建)
step_runtimes() {
  if is_done runtimes; then
    ok "全部目标运行库已就绪，跳过"
    return
  fi
  log "构建目标运行库全集 (musl -> compiler-rt -> libc++)"
  step_musl
  step_compiler_rt
  step_libcxx
  mark runtimes
  ok "全部目标运行库构建并安装完成"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_runtimes
fi
