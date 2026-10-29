#!/usr/bin/env bash
# ==============================================================================
# scripts/runtimes.sh - 目标端裸机运行库构建 (Picolibc + compiler-rt)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/picolibc.sh"
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

# 编译单个 multilib 架构矩阵的 compiler-rt builtins 与 crtbegin/crtend
build_compiler_rt_variant() {
  local target_trip="$1"  # riscv32-unknown-elf 或 riscv64-unknown-elf
  local march="$2"        # 例如 rv32imafc
  local mabi="$3"         # 例如 ilp32f
  local rel_dir="$4"      # 例如 rv32imafc/ilp32f 或 .
  local arch="$5"         # riscv32 或 riscv64
  local clang_ver="$6"

  local bdir="${BUILD_RUNTIMES:-$SRC/build-runtimes}-${target_trip}-${march}-${mabi}"
  mkdir -p "$bdir"

  local cfg_stamp="$bdir/.configured_state"
  local cur_cfg="${target_trip}|${march}|${mabi}|${SYSROOT}"
  local builtin_lib="$bdir/compiler-rt/lib/generic/libclang_rt.builtins-${arch}.a"

  if [ ! -f "$builtin_lib" ] || [ ! -f "$cfg_stamp" ] || [ "$(cat "$cfg_stamp" 2>/dev/null)" != "$cur_cfg" ]; then
    log "配置与编译 compiler-rt builtins [$target_trip, -march=$march -mabi=$mabi]"
    rm -f "$bdir/build.ninja" "$bdir/CMakeCache.txt"
    echo "$cur_cfg" > "$cfg_stamp"

    local ccache_flag=()
    if [ "${ENABLE_CCACHE:-AUTO}" != "OFF" ] && [ -x "$BOOT/bin/ccache" ]; then
      ccache_flag=("-DLLVM_CCACHE_BUILD=ON")
    fi

    "$BOOT/bin/cmake" -G Ninja \
      -S "$LLVM_DIR/runtimes" \
      -B "$bdir" \
      -DCMAKE_BUILD_TYPE="${RUNTIMES_BUILD_TYPE:-Release}" \
      -DCMAKE_SYSTEM_NAME=Generic \
      -DCMAKE_SYSTEM_PROCESSOR=riscv \
      -DCMAKE_C_COMPILER="$target_clang" \
      -DCMAKE_CXX_COMPILER="$target_clangxx" \
      -DCMAKE_ASM_COMPILER="$target_clang" \
      -DCMAKE_AR="$target_ar" \
      -DCMAKE_NM="$target_nm" \
      -DCMAKE_RANLIB="$target_ranlib" \
      -DCMAKE_C_FLAGS="-march=$march -mabi=$mabi" \
      -DCMAKE_CXX_FLAGS="-march=$march -mabi=$mabi" \
      -DCMAKE_ASM_FLAGS="-march=$march -mabi=$mabi" \
      -DLLVM_ENABLE_RUNTIMES="compiler-rt" \
      -DCMAKE_C_COMPILER_TARGET="$target_trip" \
      -DCMAKE_CXX_COMPILER_TARGET="$target_trip" \
      -DCMAKE_ASM_COMPILER_TARGET="$target_trip" \
      -DCMAKE_SYSROOT="$SYSROOT" \
      -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
      -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
      -DCOMPILER_RT_BUILD_CRT=OFF \
      -DCOMPILER_RT_BUILD_BUILTINS=ON \
      -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
      -DCOMPILER_RT_BUILD_XRAY=OFF \
      -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
      -DCOMPILER_RT_BUILD_PROFILE=OFF \
      -DCOMPILER_RT_BUILD_MEMPROF=OFF \
      -DCOMPILER_RT_BUILD_ORC=OFF \
      -DCOMPILER_RT_BAREMETAL_BUILD=ON \
      -DCOMPILER_RT_INCLUDE_TESTS=OFF \
      -DLLVM_PARALLEL_LINK_JOBS=1 \
      "${ccache_flag[@]}"

    "$BOOT/bin/ninja" -C "$bdir" -j"$JOBS" builtins
  fi

  # 编译对应架构与 ABI 的 crtbegin.o 与 crtend.o
  local tmp_crt="$bdir/crt"
  mkdir -p "$tmp_crt"
  "$target_clang" --target="$target_trip" -march="$march" -mabi="$mabi" \
    -c "$LLVM_DIR/compiler-rt/lib/builtins/crtbegin.c" -o "$tmp_crt/clang_rt.crtbegin.o"
  "$target_clang" --target="$target_trip" -march="$march" -mabi="$mabi" \
    -c "$LLVM_DIR/compiler-rt/lib/builtins/crtend.c" -o "$tmp_crt/clang_rt.crtend.o"

  # 部署到目标目录
  local norm_trip="${target_trip//-unknown-elf/-unknown-unknown-elf}"
  local res_dirs=(
    "$INSTALL/lib/clang/$clang_ver/lib/$target_trip"
    "$INSTALL/lib/clang/$clang_ver/lib/$norm_trip"
  )

  local sysroot_lib_dir="$SYSROOT/lib"
  [ "$rel_dir" != "." ] && sysroot_lib_dir="$SYSROOT/lib/$rel_dir"

  # 写入 sysroot 目标目录
  mkdir -p "$sysroot_lib_dir"
  cp -a "$builtin_lib" "$sysroot_lib_dir/libclang_rt.builtins.a"
  cp -a "$builtin_lib" "$sysroot_lib_dir/libclang_rt.builtins-${arch}.a"
  cp -a "$tmp_crt/clang_rt.crtbegin.o" "$sysroot_lib_dir/clang_rt.crtbegin.o"
  cp -a "$tmp_crt/clang_rt.crtend.o" "$sysroot_lib_dir/clang_rt.crtend.o"
  if [ "$rel_dir" != "." ]; then
    mkdir -p "$SYSROOT/$rel_dir/lib"
    cp -a "$builtin_lib" "$SYSROOT/$rel_dir/lib/libclang_rt.builtins.a"
    cp -a "$builtin_lib" "$SYSROOT/$rel_dir/lib/libclang_rt.builtins-${arch}.a"
    cp -a "$tmp_crt/clang_rt.crtbegin.o" "$SYSROOT/$rel_dir/lib/clang_rt.crtbegin.o"
    cp -a "$tmp_crt/clang_rt.crtend.o" "$SYSROOT/$rel_dir/lib/clang_rt.crtend.o"
  fi

  # 写入 Clang 资源目录
  for rdir in "${res_dirs[@]}"; do
    local dest_rdir="$rdir"
    [ "$rel_dir" != "." ] && dest_rdir="$rdir/$rel_dir"
    mkdir -p "$dest_rdir"
    cp -a "$builtin_lib" "$dest_rdir/libclang_rt.builtins.a"
    cp -a "$builtin_lib" "$dest_rdir/libclang_rt.builtins-${arch}.a"
    cp -a "$tmp_crt/clang_rt.crtbegin.o" "$dest_rdir/clang_rt.crtbegin.o"
    cp -a "$tmp_crt/clang_rt.crtend.o" "$dest_rdir/clang_rt.crtend.o"
  done

  # 写入 baremetal 目录备查
  local baremetal_dir="$INSTALL/lib/clang/$clang_ver/lib/baremetal"
  mkdir -p "$baremetal_dir"
  cp -a "$builtin_lib" "$baremetal_dir/libclang_rt.builtins-${arch}.a"

  # 若为 64 位默认目标 (rv64imafdc/lp64d)，同时同步至 64 位根资源目录与 sysroot 根目录
  if [ "$rel_dir" = "rv64imafdc/lp64d" ]; then
    for rdir in "${res_dirs[@]}"; do
      mkdir -p "$rdir"
      cp -a "$builtin_lib" "$rdir/libclang_rt.builtins.a"
      cp -a "$builtin_lib" "$rdir/libclang_rt.builtins-${arch}.a"
      cp -a "$tmp_crt/clang_rt.crtbegin.o" "$rdir/clang_rt.crtbegin.o"
      cp -a "$tmp_crt/clang_rt.crtend.o" "$rdir/clang_rt.crtend.o"
    done
    cp -a "$builtin_lib" "$SYSROOT/lib/libclang_rt.builtins-riscv64.a"
  fi

  ok "架构矩阵 $rel_dir ($target_trip, -march=$march -mabi=$mabi) 运行库就绪"
}

# 编译并部署 compiler-rt
step_compiler_rt() {
  if is_done compiler_rt; then
    ok "compiler-rt (builtins/crt) 已就绪，跳过"
    return
  fi
  step_picolibc
  get_target_tools

  local clang_ver
  clang_ver=$("$target_clang" -dumpversion 2>/dev/null | cut -d. -f1 || echo "20")

  log "编译并部署 Multilib 全矩阵 compiler-rt builtins 与 crt 启动对象"

  # 8 大 Multilib 架构矩阵目标列表: target_trip:march:mabi:rel_dir:arch
  local multilib_targets=(
    "riscv32-unknown-elf:rv32i:ilp32:rv32i/ilp32:riscv32"
    "riscv32-unknown-elf:rv32im:ilp32:rv32im/ilp32:riscv32"
    "riscv32-unknown-elf:rv32iac:ilp32:rv32iac/ilp32:riscv32"
    "riscv32-unknown-elf:rv32imac:ilp32:.:riscv32"
    "riscv32-unknown-elf:rv32imafc:ilp32f:rv32imafc/ilp32f:riscv32"
    "riscv32-unknown-elf:rv32imafdc:ilp32d:rv32imafdc/ilp32d:riscv32"
    "riscv64-unknown-elf:rv64imac:lp64:rv64imac/lp64:riscv64"
    "riscv64-unknown-elf:rv64imafdc:lp64d:rv64imafdc/lp64d:riscv64"
  )

  for entry in "${multilib_targets[@]}"; do
    local ttrip march mabi rdir arch
    ttrip="$(echo "$entry" | cut -d: -f1)"
    march="$(echo "$entry" | cut -d: -f2)"
    mabi="$(echo "$entry" | cut -d: -f3)"
    rdir="$(echo "$entry" | cut -d: -f4)"
    arch="$(echo "$entry" | cut -d: -f5)"

    build_compiler_rt_variant "$ttrip" "$march" "$mabi" "$rdir" "$arch" "$clang_ver"
  done

  mark compiler_rt
  mark builtins
  ok "全部 Multilib 矩阵 compiler-rt builtins 与 crt 运行库部署完成"
}

# 统一目标端运行库构建
step_runtimes() {
  if is_done runtimes; then
    ok "全部目标运行库已就绪，跳过"
    return
  fi
  log "构建目标运行库 (picolibc -> compiler-rt builtins)"
  step_picolibc
  step_compiler_rt
  mark runtimes
  ok "全部目标运行库构建并安装完成"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_runtimes
fi
