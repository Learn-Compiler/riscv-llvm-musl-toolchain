#!/usr/bin/env bash
# ==============================================================================
# scripts/06_prune.sh - 精简与专业化修整（剔除无关跨平台工具、剥离符号、生成 .cfg 与三元组链接）
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
init_config

step_prune() {
  log "4b/5 精简工具链（剥离无关工具、宿主符号，生成 .cfg 与三元组链接）"

  [ -d "$INSTALL/bin" ] || die "未找到安装目录 $INSTALL/bin，请先完成构建"

  # 1. 移除无关平台的工具与中间件（Windows, macOS, WebAssembly, GPU offload, 静态分析 Python 网页工具）
  local useless_bins=(
    # macOS
    clang-installapi ld64.lld
    # Windows
    clang-cl lld-link llvm-ml llvm-ml64 llvm-mt llvm-pdbutil llvm-rc
    # WebAssembly
    wasm-ld
    # GPU / Offload
    amdgpu-arch nvptx-arch clang-nvlink-wrapper clang-offload-bundler clang-sycl-linker offload-arch
    # 冗余/重量级分析与调试工具
    clang-repl clang-extdef-mapping clang-check clang-refactor clang-scan-deps diagtool
    llvm-dwp llvm-mca llvm-profgen
    # 静态分析 Web 脚本
    scan-build scan-build-py scan-view analyze-build intercept-build hmaptool git-clang-format
  )

  for b in "${useless_bins[@]}"; do
    rm -f "$INSTALL/bin/$b"
  done

  # 移除静态分析器与无关头文件目录
  rm -rf "$INSTALL/share/scan-view" "$INSTALL/share/scan-build" "$INSTALL/share/opt-viewer"
  rm -rf "$INSTALL/lib/libear" "$INSTALL/lib/libscanbuild" "$INSTALL/libexec"
  rm -rf "$INSTALL/include/mach-o"

  # 2. 调试符号剥离控制（Strip）
  local should_strip="$STRIP_SYMBOLS"
  if [ "$should_strip" = "AUTO" ]; then
    if [ "$BUILD_TYPE" = "Release" ]; then
      should_strip="ON"
    else
      should_strip="OFF"
    fi
  fi

  if [ "$should_strip" = "ON" ]; then
    echo "  正在剥离调试符号 (Strip) ..."
    for f in "$INSTALL/bin"/*; do
      if [ -f "$f" ] && [ ! -L "$f" ] && file "$f" | grep -q 'ELF.*x86-64'; then
        strip -s "$f" 2>/dev/null || true
      fi
    done
    for f in "$INSTALL/lib"/*.so*; do
      if [ -f "$f" ] && [ ! -L "$f" ] && file "$f" | grep -q 'ELF.*x86-64'; then
        strip --strip-unneeded "$f" 2>/dev/null || true
      fi
    done
  else
    ok "保留二进制调试符号 (STRIP_SYMBOLS=$should_strip, BUILD_TYPE=$BUILD_TYPE)"
  fi

  # 3. 补全标准 llvm 工具符号链接
  [ -e "$INSTALL/bin/llvm-readelf" ] || ln -sf llvm-readobj "$INSTALL/bin/llvm-readelf"

  # 4. 生成交叉编译三元组前缀软链接（方便直接作为 CROSS_COMPILE 使用）
  for tool in clang clang++ cpp ld ar as nm objcopy objdump ranlib readelf strip size strings; do
    case "$tool" in
      clang)   target="clang" ;;
      clang++) target="clang++" ;;
      cpp)     target="clang-cpp" ;;
      ld)      target="ld.lld" ;;
      as)      target="clang" ;;
      ar|nm|objcopy|objdump|ranlib|readelf|strip|size|strings) target="llvm-$tool" ;;
    esac
    ln -sf "$target" "$INSTALL/bin/${T}-${tool}"
  done
  # 兼容 gcc / g++ 别名
  ln -sf clang   "$INSTALL/bin/${T}-gcc"
  ln -sf clang++ "$INSTALL/bin/${T}-g++"

  # 5. 生成 Clang 自动装载的 .cfg 配置文件（免手动指定 --target 和 --sysroot）
  cat > "$INSTALL/bin/${T}.cfg" <<EOF
--target=${TARGET_TRIPLE}
--sysroot=<CFGDIR>/../sysroot
-fuse-ld=lld
-rtlib=compiler-rt
-unwindlib=libunwind
-stdlib=libc++
EOF

  mark prune
  ok "工具链精简与 .cfg 配置完成"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_prune
fi
