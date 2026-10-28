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

# 确保 build-runtimes CMake 配置就绪 (compiler-rt for baremetal)
ensure_compiler_rt_configured() {
  local target_trip="${1:-$T}"
  local target_arch="${2:-riscv32}"
  local RUNTIMES_BUILD="${BUILD_RUNTIMES:-$SRC/build-runtimes}-${target_trip}"
  mkdir -p "$RUNTIMES_BUILD"
  
  local target_cflags="${TARGET_EXTRA_CFLAGS:-}"
  if [ "$target_arch" = "riscv64" ]; then
    target_cflags="-march=rv64imafdc -mabi=lp64d"
  fi

  local cfg_stamp="$RUNTIMES_BUILD/.configured_state"
  local current_cfg_state="${target_trip}|${SYSROOT}|${target_cflags}"
  if [ -f "$RUNTIMES_BUILD/build.ninja" ] && [ -f "$cfg_stamp" ] && [ "$(cat "$cfg_stamp" 2>/dev/null)" = "$current_cfg_state" ]; then
    return 0
  fi
  rm -f "$RUNTIMES_BUILD/build.ninja" "$RUNTIMES_BUILD/CMakeCache.txt"
  echo "$current_cfg_state" > "$cfg_stamp"

  log "配置 compiler-rt 目标运行库 CMake [Target: $target_trip, Sysroot: $SYSROOT]"
  get_target_tools

  local ccache_flag=()
  if [ "${ENABLE_CCACHE:-AUTO}" != "OFF" ] && [ -x "$BOOT/bin/ccache" ]; then
    ccache_flag=("-DLLVM_CCACHE_BUILD=ON")
  fi

  "$BOOT/bin/cmake" -G Ninja \
    -S "$LLVM_DIR/runtimes" \
    -B "$RUNTIMES_BUILD" \
    -DCMAKE_BUILD_TYPE="${RUNTIMES_BUILD_TYPE:-Release}" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL" \
    -DCMAKE_SYSTEM_NAME=Generic \
    -DCMAKE_SYSTEM_PROCESSOR=riscv \
    -DCMAKE_C_COMPILER="$target_clang" \
    -DCMAKE_CXX_COMPILER="$target_clangxx" \
    -DCMAKE_ASM_COMPILER="$target_clang" \
    -DCMAKE_AR="$target_ar" \
    -DCMAKE_NM="$target_nm" \
    -DCMAKE_RANLIB="$target_ranlib" \
    -DCMAKE_C_FLAGS="$target_cflags" \
    -DCMAKE_CXX_FLAGS="$target_cflags" \
    -DCMAKE_ASM_FLAGS="$target_cflags" \
    -DLLVM_ENABLE_RUNTIMES="compiler-rt" \
    -DCMAKE_C_COMPILER_TARGET="$target_trip" \
    -DCMAKE_CXX_COMPILER_TARGET="$target_trip" \
    -DCMAKE_ASM_COMPILER_TARGET="$target_trip" \
    -DCMAKE_SYSROOT="$SYSROOT" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    -DCOMPILER_RT_BUILD_CRT=ON \
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
  clang_ver=$("$target_clang" -dumpversion 2>/dev/null | cut -d. -f1 || echo "23")

  # 1. 编译并部署 riscv32-unknown-elf 的 builtins 与 crt
  ensure_compiler_rt_configured "riscv32-unknown-elf" "riscv32"
  local RUNTIMES_BUILD_32="${BUILD_RUNTIMES:-$SRC/build-runtimes}-riscv32-unknown-elf"
  log "编译 riscv32 compiler-rt 目标库"
  "$BOOT/bin/ninja" -C "$RUNTIMES_BUILD_32" -j"$JOBS" install-compiler-rt

  local inst_res_32="$INSTALL/lib/clang/$clang_ver/lib/riscv32-unknown-elf"
  local inst_baremetal_32="$INSTALL/lib/clang/$clang_ver/lib/baremetal"
  mkdir -p "$inst_res_32" "$inst_baremetal_32" "$SYSROOT/lib"

  for b in "$RUNTIMES_BUILD_32/compiler-rt/lib/generic/libclang_rt.builtins-riscv32.a" \
           "$RUNTIMES_BUILD_32/compiler-rt/lib/baremetal/libclang_rt.builtins-riscv32.a" \
           "$INSTALL/lib/generic/libclang_rt.builtins-riscv32.a" \
           "$INSTALL/lib/baremetal/libclang_rt.builtins-riscv32.a" \
           "$INSTALL/lib/riscv32-unknown-elf/libclang_rt.builtins.a"; do
    if [ -f "$b" ]; then
      cp -a "$b" "$inst_res_32/libclang_rt.builtins.a"
      cp -a "$b" "$inst_res_32/libclang_rt.builtins-riscv32.a"
      cp -a "$b" "$SYSROOT/lib/libclang_rt.builtins.a"
      cp -a "$b" "$SYSROOT/lib/libclang_rt.builtins-riscv32.a"
      cp -a "$b" "$inst_baremetal_32/libclang_rt.builtins-riscv32.a"
      break
    fi
  done

  # 编译并部署 riscv32 的 crtbegin.o 与 crtend.o
  log "编译 riscv32 crtbegin.o 与 crtend.o"
  "$target_clang" --target=riscv32-unknown-elf -march=rv32imac -mabi=ilp32 -c "$LLVM_DIR/compiler-rt/lib/builtins/crtbegin.c" -o "$inst_res_32/clang_rt.crtbegin.o"
  "$target_clang" --target=riscv32-unknown-elf -march=rv32imac -mabi=ilp32 -c "$LLVM_DIR/compiler-rt/lib/builtins/crtend.c" -o "$inst_res_32/clang_rt.crtend.o"
  cp -a "$inst_res_32/clang_rt.crtbegin.o" "$SYSROOT/lib/clang_rt.crtbegin.o"
  cp -a "$inst_res_32/clang_rt.crtend.o" "$SYSROOT/lib/clang_rt.crtend.o"

  # 2. 编译并部署 riscv64-unknown-elf 的 builtins 与 crt
  ensure_compiler_rt_configured "riscv64-unknown-elf" "riscv64"
  local RUNTIMES_BUILD_64="${BUILD_RUNTIMES:-$SRC/build-runtimes}-riscv64-unknown-elf"
  log "编译 riscv64 compiler-rt 目标库"
  "$BOOT/bin/ninja" -C "$RUNTIMES_BUILD_64" -j"$JOBS" install-compiler-rt

  local inst_res_64="$INSTALL/lib/clang/$clang_ver/lib/riscv64-unknown-elf"
  mkdir -p "$inst_res_64"
  for b in "$RUNTIMES_BUILD_64/compiler-rt/lib/generic/libclang_rt.builtins-riscv64.a" \
           "$RUNTIMES_BUILD_64/compiler-rt/lib/baremetal/libclang_rt.builtins-riscv64.a" \
           "$INSTALL/lib/generic/libclang_rt.builtins-riscv64.a" \
           "$INSTALL/lib/baremetal/libclang_rt.builtins-riscv64.a" \
           "$INSTALL/lib/riscv64-unknown-elf/libclang_rt.builtins.a"; do
    if [ -f "$b" ]; then
      cp -a "$b" "$inst_res_64/libclang_rt.builtins.a"
      cp -a "$b" "$inst_res_64/libclang_rt.builtins-riscv64.a"
      cp -a "$b" "$SYSROOT/lib/libclang_rt.builtins-riscv64.a"
      cp -a "$b" "$inst_baremetal_32/libclang_rt.builtins-riscv64.a"
      break
    fi
  done

  # 编译并部署 riscv64 的 crtbegin.o 与 crtend.o
  log "编译 riscv64 crtbegin.o 与 crtend.o"
  "$target_clang" --target=riscv64-unknown-elf -march=rv64gc -mabi=lp64d -c "$LLVM_DIR/compiler-rt/lib/builtins/crtbegin.c" -o "$inst_res_64/clang_rt.crtbegin.o"
  "$target_clang" --target=riscv64-unknown-elf -march=rv64gc -mabi=lp64d -c "$LLVM_DIR/compiler-rt/lib/builtins/crtend.c" -o "$inst_res_64/clang_rt.crtend.o"

  # 3. 部署 Clang resource-dir 下的标准化与 multilib 软链接 (支持 riscv*-unknown-unknown-elf)
  local inst_uue_32="$INSTALL/lib/clang/$clang_ver/lib/riscv32-unknown-unknown-elf"
  local inst_uue_64="$INSTALL/lib/clang/$clang_ver/lib/riscv64-unknown-unknown-elf"
  mkdir -p "$inst_uue_32" "$inst_uue_64"
  cp -a "$inst_res_32"/* "$inst_uue_32/" 2>/dev/null || true
  cp -a "$inst_res_64"/* "$inst_uue_64/" 2>/dev/null || true

  for v in rv32i/ilp32 rv32im/ilp32 rv32iac/ilp32 rv32imafc/ilp32f rv32imafdc/ilp32d; do
    mkdir -p "$inst_uue_32/$v" "$SYSROOT/lib/$v"
    ln -sfn ../../libclang_rt.builtins-riscv32.a "$inst_uue_32/$v/libclang_rt.builtins.a"
    ln -sfn ../../clang_rt.crtbegin.o "$inst_uue_32/$v/clang_rt.crtbegin.o"
    ln -sfn ../../clang_rt.crtend.o "$inst_uue_32/$v/clang_rt.crtend.o"
    ln -sfn ../libclang_rt.builtins-riscv32.a "$SYSROOT/lib/$v/libclang_rt.builtins.a" 2>/dev/null || true
  done

  for v in rv64imac/lp64 rv64imafdc/lp64d; do
    mkdir -p "$inst_uue_64/$v" "$SYSROOT/lib/$v"
    ln -sfn ../../libclang_rt.builtins-riscv64.a "$inst_uue_64/$v/libclang_rt.builtins.a"
    ln -sfn ../../clang_rt.crtbegin.o "$inst_uue_64/$v/clang_rt.crtbegin.o"
    ln -sfn ../../clang_rt.crtend.o "$inst_uue_64/$v/clang_rt.crtend.o"
    ln -sfn ../libclang_rt.builtins-riscv64.a "$SYSROOT/lib/$v/libclang_rt.builtins.a" 2>/dev/null || true
  done

  mark compiler_rt
  mark builtins
  ok "compiler-rt builtins 与 crt 运行库部署完成"
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
