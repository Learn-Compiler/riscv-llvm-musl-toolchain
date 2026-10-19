#!/usr/bin/env bash
# ==============================================================================
# scripts/verify.sh - 工具链功能验证与 C/C++ 冒烟测试
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
init_config

# 验证目标运行库（静态库/共享库）
verify_runtime_libs() {
  # --- 目标静态运行库检查 ---
  [ -f "$SYSROOT/usr/lib/libc.a" ] || die "缺少静态 C 运行库: $SYSROOT/usr/lib/libc.a"
  ok "找到静态 libc.a"

  if [ -f "$SYSROOT/lib/libc++.a" ] || [ -f "$SYSROOT/usr/lib/libc++.a" ]; then
    ok "找到静态 libc++.a"
  else
    die "缺少静态 C++ 运行库 libc++.a"
  fi

  if [ -f "$SYSROOT/lib/libunwind.a" ] || [ -f "$SYSROOT/usr/lib/libunwind.a" ]; then
    ok "找到静态 libunwind.a"
  else
    die "缺少静态 unwinder 运行库 libunwind.a"
  fi

  if [ "${ENABLE_SHARED:-OFF}" = "OFF" ]; then
    if ls "$SYSROOT"/lib/*.so* "$SYSROOT"/usr/lib/*.so* >/dev/null 2>&1; then
      warn "Sysroot 中存在 .so 共享库文件（如不需要共享库请核实）"
    else
      ok "确认 Sysroot 纯静态化（无 .so 共享库）"
    fi
  else
    [ -e "$SYSROOT/lib/$LD_MUSL_SO" ] || [ -e "$SYSROOT/usr/lib/libc.so" ] || die "共享库模式下缺少动态链接器/libc.so"
    ok "确认 Sysroot 包含共享库支持 ($LD_MUSL_SO)"
  fi
}

step_verify() {
  log "验证工具链与冒烟测试"

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

  # --- 校验目标运行库（静态库/共享库） ---
  verify_runtime_libs

  # --- 冒烟测试：C ---
  local wd="$BUILD/smoke"
  mkdir -p "$wd"
  cat > "$wd/hello.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
int main(void){ printf("hello from %s\n", "musl+clang"); return 0; }
EOF
  local c_static_flag=""
  if [ "${ENABLE_SHARED:-OFF}" = "OFF" ] || [ "${DEFAULT_STATIC_LINK:-ON}" = "ON" ]; then
    c_static_flag="-static"
  fi
  "$INSTALL/bin/clang" --target="$T" --sysroot="$SYSROOT" $c_static_flag \
      "$wd/hello.c" -o "$wd/hello"
  file "$wd/hello" | grep -q "${SMOKE_TEST_PATTERN:-UCB RISC-V}" \
    || die "C 冒烟测试产物不是目标架构 (${SMOKE_TEST_PATTERN:-UCB RISC-V})"
  if [ -n "$c_static_flag" ]; then
    file "$wd/hello" | grep -q "statically linked" \
      || die "C 冒烟测试产物不是静态链接"
    ok "C 静态链接成功（且未依赖 libgcc）"
  else
    ok "C 动态链接成功"
  fi

  # --- 冒烟测试：C++ / libc++ ---
  cat > "$wd/h.cpp" <<'EOF'
#include <iostream>
#include <vector>
#include <string>
int main(){ std::vector<std::string> v{"ok"}; std::cout << v[0] << "\n"; }
EOF
  "$INSTALL/bin/clang++" --target="$T" --sysroot="$SYSROOT" -stdlib=libc++ $c_static_flag \
      "$wd/h.cpp" -o "$wd/h"
  file "$wd/h" | grep -q "${SMOKE_TEST_PATTERN:-UCB RISC-V}" \
    || die "C++ 冒烟测试产物不是目标架构 (${SMOKE_TEST_PATTERN:-UCB RISC-V})"
  if [ -n "$c_static_flag" ]; then
    file "$wd/h" | grep -q "statically linked" \
      || die "C++ 冒烟测试产物不是静态链接"
    ok "C++/libc++ 静态链接成功"
  else
    ok "C++/libc++ 动态链接成功"
  fi

  # --- 冒烟测试：三元组别名与 .cfg 免参数编译 ---
  if [ -x "$INSTALL/bin/${T}-clang" ]; then
    "$INSTALL/bin/${T}-clang" "$wd/hello.c" -o "$wd/hello-cfg"
    file "$wd/hello-cfg" | grep -q "${SMOKE_TEST_PATTERN:-UCB RISC-V}" \
      || die "三元组前缀 clang 编译测试失败"
    if [ "${DEFAULT_STATIC_LINK:-ON}" = "ON" ]; then
      file "$wd/hello-cfg" | grep -q "statically linked" \
        || die "三元组别名 ${T}-clang 未默认静态链接"
      ok "三元组别名 ${T}-clang (.cfg 自动装载) 默认静态链接成功"
    else
      ok "三元组别名 ${T}-clang (.cfg 自动装载) 编译成功"
    fi
  fi

  if [ -x "$INSTALL/bin/${T}-clang++" ]; then
    "$INSTALL/bin/${T}-clang++" "$wd/h.cpp" -o "$wd/h-cfg"
    file "$wd/h-cfg" | grep -q "${SMOKE_TEST_PATTERN:-UCB RISC-V}" \
      || die "三元组前缀 clang++ 编译测试失败"
    if [ "${DEFAULT_STATIC_LINK:-ON}" = "ON" ]; then
      file "$wd/h-cfg" | grep -q "statically linked" \
        || die "三元组别名 ${T}-clang++ 未默认静态链接"
      ok "三元组别名 ${T}-clang++ (.cfg 自动装载) 默认静态链接成功"
    else
      ok "三元组别名 ${T}-clang++ (.cfg 自动装载) 编译成功"
    fi
  fi

  # --- 冒烟测试：MLIR (若启用/已安装) ---
  if [ -x "$INSTALL/bin/mlir-opt" ]; then
    echo "  正在执行 MLIR 冒烟测试 ..."
    "$INSTALL/bin/mlir-opt" --version >/dev/null 2>&1 || die "mlir-opt 无法执行"
    cat > "$wd/test.mlir" <<'EOF'
module {
  func.func @test(%arg0: i32) -> i32 {
    return %arg0 : i32
  }
}
EOF
    "$INSTALL/bin/mlir-opt" "$wd/test.mlir" -o "$wd/test_opt.mlir" || die "mlir-opt 解析/优化基础 MLIR 失败"
    ok "MLIR (mlir-opt) 功能测试通过"
  fi

  # --- 冒烟测试：torch-mlir (若启用/已安装) ---
  if [ -x "$INSTALL/bin/torch-mlir-opt" ]; then
    echo "  正在执行 torch-mlir 冒烟测试 ..."
    "$INSTALL/bin/torch-mlir-opt" --version >/dev/null 2>&1 || die "torch-mlir-opt 无法执行"
    cat > "$wd/torch_test.mlir" <<'EOF'
module {
  func.func @torch_add(%arg0: !torch.int, %arg1: !torch.int) -> !torch.int {
    return %arg0 : !torch.int
  }
}
EOF
    "$INSTALL/bin/torch-mlir-opt" "$wd/torch_test.mlir" -o "$wd/torch_test_opt.mlir" || die "torch-mlir-opt 解析基础 torch 方言失败"
    ok "torch-mlir (torch-mlir-opt) 方言与工具链测试通过"
  fi

  mark verify
  ok "验证全部通过"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_verify
fi
