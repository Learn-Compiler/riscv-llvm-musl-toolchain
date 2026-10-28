#!/usr/bin/env bash
# ==============================================================================
# scripts/verify.sh - 裸机 ELF 工具链功能验证与多 march 矩阵冒烟测试
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
init_config

# 验证目标运行库（静态库/启动对象/多 march 矩阵）
verify_runtime_libs() {
  log "校验目标端基础运行库与 Multilib 矩阵产物"
  
  [ -f "$SYSROOT/lib/libc.a" ] || die "缺少静态 C 运行库: $SYSROOT/lib/libc.a"
  ok "找到主 libc.a"

  [ -f "$SYSROOT/lib/libm.a" ] || die "缺少静态数学库: $SYSROOT/lib/libm.a"
  ok "找到主 libm.a"

  [ -f "$SYSROOT/lib/crt0.o" ] || die "缺少启动文件: $SYSROOT/lib/crt0.o"
  ok "找到主 crt0.o"

  # 检查 multilib 矩阵目标库
  local checked_subdirs=0
  for v in rv32i/ilp32 rv32im/ilp32 rv32iac/ilp32 rv32imafc/ilp32f rv32imafdc/ilp32d rv64imac/lp64 rv64imafdc/lp64d; do
    if [ -f "$SYSROOT/lib/$v/libc.a" ]; then
      ok "找到矩阵目标库: $v/libc.a"
      checked_subdirs=$((checked_subdirs + 1))
    fi
  done
  log "已成功校验 $checked_subdirs 个 Multilib 架构矩阵目标库"
}

step_verify() {
  log "开始验证工具链与执行冒烟测试"

  [ -x "$INSTALL/bin/clang" ] || die "缺少编译器 $INSTALL/bin/clang，请先完成构建"

  # 校验 compiler-rt builtins
  local clang_ver
  clang_ver=$("$INSTALL/bin/clang" -dumpversion 2>/dev/null | cut -d. -f1 || echo "23")
  local builtin_found=0
  for b in "$INSTALL/lib/clang/$clang_ver/lib/riscv32-unknown-elf/libclang_rt.builtins.a" \
           "$INSTALL/lib/clang/$clang_ver/lib/baremetal/libclang_rt.builtins-riscv32.a" \
           "$SYSROOT/lib/libclang_rt.builtins-riscv32.a" \
           "$SYSROOT/lib/libclang_rt.builtins.a"; do
    if [ -f "$b" ]; then
      ok "找到 builtins 运行时: $b"
      builtin_found=1
      break
    fi
  done
  [ "$builtin_found" = 1 ] || die "compiler-rt builtins 运行时缺失"

  # 校验运行库产物
  verify_runtime_libs

  # ─── 冒烟测试：C 程序编译与目标架构校验 ──────────────────────────────
  local wd="$BUILD/smoke"
  mkdir -p "$wd"
  cat > "$wd/hello.c" <<'EOF'
#include <stdio.h>
int main(void) {
  printf("Hello from RISC-V Baremetal ELF!\n");
  return 0;
}
EOF

  # 1. 默认架构 (riscv32-unknown-elf) 编译冒烟测试
  log "测试 1: 默认 riscv32-unknown-elf 编译"
  "$INSTALL/bin/clang" --target=riscv32-unknown-elf --sysroot="$SYSROOT" \
    "$wd/hello.c" -o "$wd/hello-rv32"
  file "$wd/hello-rv32" | grep -q "ELF 32-bit" || die "hello-rv32 不是 32 位 ELF"
  file "$wd/hello-rv32" | grep -q "RISC-V" || die "hello-rv32 不是 RISC-V 指令集"
  ok "默认 riscv32-unknown-elf 编译通过 (32-bit RISC-V ELF)"

  # 2. 多 march 矩阵编译冒烟测试
  log "测试 2: 多 march 矩阵编译测试"
  local test_matrix=(
    "rv32i:-march=rv32i -mabi=ilp32:32-bit"
    "rv32im:-march=rv32im -mabi=ilp32:32-bit"
    "rv32iac:-march=rv32iac -mabi=ilp32:32-bit"
    "rv32imac:-march=rv32imac -mabi=ilp32:32-bit"
    "rv32imafc:-march=rv32imafc -mabi=ilp32f:32-bit"
    "rv32imafdc:-march=rv32imafdc -mabi=ilp32d:32-bit"
    "rv64imac:-march=rv64imac -mabi=lp64:64-bit"
    "rv64imafdc:-march=rv64imafdc -mabi=lp64d:64-bit"
  )

  for item in "${test_matrix[@]}"; do
    local mname mflags ebit
    mname="$(echo "$item" | cut -d: -f1)"
    mflags="$(echo "$item" | cut -d: -f2)"
    ebit="$(echo "$item" | cut -d: -f3)"

    local ttrip="riscv32-unknown-elf"
    if [ "$ebit" = "64-bit" ]; then
      ttrip="riscv64-unknown-elf"
    fi

    # shellcheck disable=SC2086
    "$INSTALL/bin/clang" --target="$ttrip" --sysroot="$SYSROOT" $mflags \
      "$wd/hello.c" -o "$wd/hello-$mname"
    [ -f "$wd/hello-$mname" ] || die "矩阵目标 $mname ($mflags) 编译测试产物缺失"
    file "$wd/hello-$mname" | grep -q "$ebit" || die "hello-$mname 架构位数不匹配: 期望 $ebit"
    ok "矩阵目标 $mname ($mflags) 编译冒烟通过 ($ebit ELF)"
  done

  # 3. 三元组软链接调用冒烟测试 (riscv32-unknown-elf-clang 与 riscv64-unknown-elf-clang)
  log "测试 3: 三元组入口调用 (软链接健全性验证)"
  if [ -x "$INSTALL/bin/riscv32-unknown-elf-clang" ]; then
    "$INSTALL/bin/riscv32-unknown-elf-clang" "$wd/hello.c" -o "$wd/hello-alias32"
    file "$wd/hello-alias32" | grep -q "ELF 32-bit" || die "riscv32-unknown-elf-clang 编译输出错误"
    ok "riscv32-unknown-elf-clang 入口直接调用成功"
  fi

  if [ -x "$INSTALL/bin/riscv64-unknown-elf-clang" ]; then
    "$INSTALL/bin/riscv64-unknown-elf-clang" -march=rv64imafdc -mabi=lp64d "$wd/hello.c" -o "$wd/hello-alias64"
    file "$wd/hello-alias64" | grep -q "ELF 64-bit" || die "riscv64-unknown-elf-clang 软链接调用输出错误"
    ok "riscv64-unknown-elf-clang 软链接入口直接调用成功 (输出 64-bit ELF)"
  fi

  # 4. 自动装载 clang.cfg 免参数直接编译
  log "测试 4: 直接调用 clang (自动装载 clang.cfg)"
  if [ -f "$INSTALL/bin/clang.cfg" ]; then
    "$INSTALL/bin/clang" "$wd/hello.c" -o "$wd/hello-cfg"
    file "$wd/hello-cfg" | grep -q "ELF 32-bit" || die "clang 免参数调用输出错误"
    ok "clang 免参数直接编译测试通过 (自动装载 clang.cfg)"
  fi

  mark verify
  ok "全部验证测试顺利通过！工具链功能完整可用。"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_verify
fi
