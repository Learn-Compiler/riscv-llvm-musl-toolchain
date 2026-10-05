#!/usr/bin/env bash
# ==============================================================================
# scripts/07_verify.sh - 工具链功能验证与 C/C++ 冒烟测试
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
init_config

step_verify() {
  log "5/5 验证"

  [ -x "$INSTALL/bin/clang" ] || die "缺少编译器 $INSTALL/bin/clang，请先完成构建"

  # --- 成败关键：compiler-rt 的 crt 必须存在 ---
  local crtdir=""
  for d in "$INSTALL"/lib/clang/*/lib/"$T" "$INSTALL"/lib/clang/*/lib/linux; do
    if [ -d "$d" ]; then crtdir="$d"; break; fi
  done
  [ -n "$crtdir" ] || die "找不到 clang 资源目录 $INSTALL/lib/clang/*"
  local missing=0
  for f in clang_rt.crtbegin.o libclang_rt.crtbegin-riscv64.o libclang_rt.crtend-riscv64.o clang_rt.crtbegin-riscv64.o clang_rt.crtend-riscv64.o crtbegin.o crtend.o; do
    if [ -e "$crtdir/$f" ]; then ok "找到 $f"; break; fi
  done
  ls "$crtdir"/libclang_rt.builtins*.a >/dev/null 2>&1 \
    && ok "找到 libclang_rt.builtins" \
    || { echo "  ✗ 缺少 builtins"; missing=1; }
  [ "$missing" = 0 ] || die "compiler-rt 运行时缺失，工具链不可用"

  # --- 目标三元组 ---
  local tri
  tri=$("$INSTALL/bin/clang" --print-target-triple --target="$T" 2>/dev/null || true)
  echo "  target triple: $tri"

  # --- 冒烟测试：C ---
  local wd="$BUILD/smoke"
  mkdir -p "$wd"
  cat > "$wd/hello.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
int main(void){ printf("hello from %s\n", "musl+clang"); return 0; }
EOF
  "$INSTALL/bin/clang" --target="$T" --sysroot="$SYSROOT" \
      "$wd/hello.c" -o "$wd/hello"
  file "$wd/hello" | grep -q "${SMOKE_TEST_PATTERN:-UCB RISC-V}" \
    || die "C 冒烟测试产物不是目标架构 (${SMOKE_TEST_PATTERN:-UCB RISC-V})"
  ok "C 链接成功（且未依赖 libgcc）"

  # --- 冒烟测试：C++ / libc++ ---
  cat > "$wd/h.cpp" <<'EOF'
#include <iostream>
#include <vector>
#include <string>
int main(){ std::vector<std::string> v{"ok"}; std::cout << v[0] << "\n"; }
EOF
  "$INSTALL/bin/clang++" --target="$T" --sysroot="$SYSROOT" -stdlib=libc++ \
      "$wd/h.cpp" -o "$wd/h"
  file "$wd/h" | grep -q "${SMOKE_TEST_PATTERN:-UCB RISC-V}" \
    || die "C++ 冒烟测试产物不是目标架构 (${SMOKE_TEST_PATTERN:-UCB RISC-V})"
  ok "C++/libc++ 链接成功"

  # --- 冒烟测试：三元组别名与 .cfg 免参数编译 ---
  if [ -x "$INSTALL/bin/${T}-clang" ]; then
    "$INSTALL/bin/${T}-clang" "$wd/hello.c" -o "$wd/hello-cfg"
    file "$wd/hello-cfg" | grep -q "${SMOKE_TEST_PATTERN:-UCB RISC-V}" \
      || die "三元组前缀 clang 编译测试失败"
    ok "三元组别名 ${T}-clang (.cfg 自动装载) 编译成功"
  fi

  mark verify
  ok "验证全部通过"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_verify
fi
