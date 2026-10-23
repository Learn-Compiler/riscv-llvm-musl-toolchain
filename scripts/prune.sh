#!/usr/bin/env bash
# ==============================================================================
# scripts/prune.sh - 方案 C: 架构解耦修整与 AI 编译器独立隔离
# ==============================================================================
# 核心职责：
#   1. 架构解耦：将 MLIR 与 Torch-MLIR 统一迁移隔离至独立 AI 目录 ($INSTALL_AI)
#   2. 工业级瘦身：剔除底层交叉工具链 ($INSTALL_TOOLCHAIN) 中的数百个内部测试工具与宿主静态库
#   3. 头文件净化：保留目标端 libc++ 运行库头文件，隔绝宿主 C++ 模板头文件污染
#   4. 别名与便携配置：生成目标平台标准交叉编译三元组软链接与 .cfg 自动装载配置
#   5. 环境联动：生成统一的 env.sh 激活脚本，一键接入 PATH / LD_LIBRARY_PATH
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
init_config

step_prune() {
  log "开始执行工具链架构解耦与工业级修整 (方案 C: 交叉工具链 + 统一 AI 编译器)"

  INSTALL_TOOLCHAIN="${INSTALL_TOOLCHAIN:-$INSTALL}"
  INSTALL_AI="${INSTALL_AI:-$SRC/install-ai}"

  # 兼容平滑迁移：若存在旧版目录且新目录未建立，自动重命名并建立兼容软链接
  if [ -d "$SRC/install-clang-musl" ] && [ ! -L "$SRC/install-clang-musl" ] && [ "$SRC/install-clang-musl" != "$INSTALL_TOOLCHAIN" ] && [ ! -d "$INSTALL_TOOLCHAIN" ]; then
    log "迁移旧版安装目录 install-clang-musl -> $INSTALL_TOOLCHAIN"
    mv "$SRC/install-clang-musl" "$INSTALL_TOOLCHAIN"
  fi
  if [ "$SRC/install-clang-musl" != "$INSTALL_TOOLCHAIN" ]; then
    ln -sfn "$INSTALL_TOOLCHAIN" "$SRC/install-clang-musl"
  fi

  [ -d "$INSTALL_TOOLCHAIN/bin" ] || die "未找到安装目录 $INSTALL_TOOLCHAIN/bin，请先完成构建"

  mkdir -p "$INSTALL_AI/bin" "$INSTALL_AI/lib" "$INSTALL_AI/include"

  # ─── 1. 架构隔离：迁移 MLIR 与 Torch-MLIR 至统一 AI 编译器目录 ───
  log "隔离 AI 编译器产物至统一目录 ($INSTALL_AI)"
  
  # 迁移 AI 可执行工具 (mlir-* / tblgen-* / torch-mlir-*)
  for p in mlir-* tblgen-* torch-mlir-* llvm-tblgen clang-tblgen; do
    for f in "$INSTALL_TOOLCHAIN/bin"/$p; do
      if [ -f "$f" ] || [ -L "$f" ]; then
        mv -f "$f" "$INSTALL_AI/bin/" 2>/dev/null || true
      fi
    done
  done

  # 迁移 AI 相关 C++ / C-API 头文件
  for d in mlir mlir-c torch-mlir torch-mlir-c torch-mlir-dialects llvm llvm-c clang clang-c lld; do
    if [ -d "$INSTALL_TOOLCHAIN/include/$d" ]; then
      rm -rf "$INSTALL_AI/include/$d"
      mv "$INSTALL_TOOLCHAIN/include/$d" "$INSTALL_AI/include/"
    fi
  done

  # 迁移 AI 相关库与 CMake 配置文件
  mkdir -p "$INSTALL_AI/lib/cmake"
  for lib_pattern in "libMLIR*" "libmlir_*" "libTorchMLIR*" "libtorch_mlir*" "libLLVM*" "libclang*" "liblld*"; do
    for f in "$INSTALL_TOOLCHAIN/lib"/$lib_pattern; do
      if [ -f "$f" ] || [ -L "$f" ]; then
        mv -f "$f" "$INSTALL_AI/lib/" 2>/dev/null || true
      fi
    done
  done

  for cmake_dir in mlir torch-mlir llvm clang lld; do
    if [ -d "$INSTALL_TOOLCHAIN/lib/cmake/$cmake_dir" ]; then
      rm -rf "$INSTALL_AI/lib/cmake/$cmake_dir"
      mv "$INSTALL_TOOLCHAIN/lib/cmake/$cmake_dir" "$INSTALL_AI/lib/cmake/"
    fi
  done

  # 清理裸 CMake 对象文件
  rm -rf "$INSTALL_TOOLCHAIN/lib/objects-Release" "$INSTALL_AI/lib/objects-Release" 2>/dev/null || true
  rm -rf "$INSTALL_TOOLCHAIN/lib/cmake" 2>/dev/null || true

  # ─── 2. 深度修整底层工具链：剔除无关跨平台与单测内部工具 ────────
  log "净化底层工具链目录 ($INSTALL_TOOLCHAIN)"
  local useless_bins=(
    scan-build scan-build-py scan-view analyze-build intercept-build hmaptool git-clang-format
    UnicodeNameMappingGenerator yaml-bench llvm-PerfectShuffle verify-uselistorder
    split-file FileCheck count not reduce-chunk-list llvm-stress llvm-test-mustache-spec
    sancov sanstats llvm-c-test clang-cl llvm-ml llvm-ml64 llvm-windres llvm-rc
    llvm-libtool-darwin llvm-dlltool llvm-cvtres llvm-install-name-tool llvm-otool
    ld64.lld wasm-ld lld-link amdgpu-arch nvptx-arch offload-arch clang-nvlink-wrapper
    clang-offload-bundler clang-offload-packager llvm-offload-binary llvm-offload-wrapper
    llvm-gpu-loader clang-repl clang-check clang-extdef-mapping clang-installapi
    clang-refactor clang-scan-deps clang-ssaf-analyzer clang-ssaf-format clang-ssaf-linker
    clang-sycl-linker diagtool dsymutil lli lli-child-target llubi llvm-bcanalyzer
    llvm-bitcode-strip llvm-cas llvm-cat llvm-cfi-verify llvm-cgdata llvm-ctxprof-util
    llvm-cxxdump llvm-cxxmap llvm-debuginfo-analyzer llvm-debuginfod llvm-debuginfod-find
    llvm-diff llvm-dwp llvm-exegesis llvm-extract-bundle-entry llvm-ifs llvm-ir2vec
    llvm-jitlink llvm-jitlink-executor llvm-lib llvm-lipo llvm-lto llvm-lto2 llvm-mca
    llvm-modextract llvm-mt llvm-opt-report llvm-pdbutil llvm-profdata llvm-profgen
    llvm-readtapi llvm-reduce llvm-remarkutil llvm-rtdyld llvm-sim llvm-tli-checker
    llvm-undname llvm-xray obj2yaml yaml2obj
  )

  for b in "${useless_bins[@]}"; do
    rm -f "$INSTALL_TOOLCHAIN/bin/$b"
  done

  # 移除静态分析器与无关头文件目录
  rm -rf "$INSTALL_TOOLCHAIN/share/scan-view" "$INSTALL_TOOLCHAIN/share/scan-build" "$INSTALL_TOOLCHAIN/share/opt-viewer"
  rm -rf "$INSTALL_TOOLCHAIN/lib/libear" "$INSTALL_TOOLCHAIN/lib/libscanbuild" "$INSTALL_TOOLCHAIN/libexec"
  rm -rf "$INSTALL_TOOLCHAIN/include/mach-o"

  # ─── 3. 调试符号剥离控制（Strip） ────────────────────────────────────
  local should_strip="$STRIP_SYMBOLS"
  if [ "$should_strip" = "AUTO" ]; then
    if [ "$BUILD_TYPE" = "Release" ]; then
      should_strip="ON"
    else
      should_strip="OFF"
    fi
  fi

  if [ "$should_strip" = "ON" ]; then
    log "正在剥离工具链与 AI 编译器二进制调试符号 (Strip) ..."
    for dir in "$INSTALL_TOOLCHAIN" "$INSTALL_AI"; do
      for f in "$dir/bin"/*; do
        if [ -f "$f" ] && [ ! -L "$f" ] && file "$f" | grep -q 'ELF.*x86-64'; then
          strip -s "$f" 2>/dev/null || true
        fi
      done
      for f in "$dir/lib"/*.so*; do
        if [ -f "$f" ] && [ ! -L "$f" ] && file "$f" | grep -q 'ELF.*x86-64'; then
          strip --strip-unneeded "$f" 2>/dev/null || true
        fi
      done
    done
  else
    ok "保留二进制调试符号 (STRIP_SYMBOLS=$should_strip, BUILD_TYPE=$BUILD_TYPE)"
  fi

  # ─── 4. 补全标准 llvm 工具符号链接与三元组软链接 ────────────────────
  [ -e "$INSTALL_TOOLCHAIN/bin/llvm-readelf" ] || ln -sf llvm-readobj "$INSTALL_TOOLCHAIN/bin/llvm-readelf"

  for tool in clang clang++ cpp ld ar as nm objcopy objdump ranlib readelf strip size strings; do
    case "$tool" in
      clang)   target="clang" ;;
      clang++) target="clang++" ;;
      cpp)     target="clang-cpp" ;;
      ld)      target="ld.lld" ;;
      as)      target="clang" ;;
      ar|nm|objcopy|objdump|ranlib|readelf|strip|size|strings) target="llvm-$tool" ;;
    esac
    ln -sf "$target" "$INSTALL_TOOLCHAIN/bin/${T}-${tool}"
  done
  # 兼容 gcc / g++ 别名
  ln -sf clang   "$INSTALL_TOOLCHAIN/bin/${T}-gcc"
  ln -sf clang++ "$INSTALL_TOOLCHAIN/bin/${T}-g++"

  # ─── 5. 生成 Clang 自动装载的 .cfg 配置文件 ────────────────────────
  cat > "$INSTALL_TOOLCHAIN/bin/${T}.cfg" <<EOF
--target=${TARGET_TRIPLE}
--sysroot=<CFGDIR>/../sysroot
-fuse-ld=lld
-rtlib=compiler-rt
-unwindlib=libunwind
-stdlib=libc++
EOF

  if [ -n "${TARGET_EXTRA_CFLAGS:-}" ]; then
    echo "${TARGET_EXTRA_CFLAGS}" >> "$INSTALL_TOOLCHAIN/bin/${T}.cfg"
  fi

  if [ "${DEFAULT_STATIC_LINK:-ON}" = "ON" ]; then
    echo "-static" >> "$INSTALL_TOOLCHAIN/bin/${T}.cfg"
  fi

  # ─── 6. 生成统一环境激活脚本 env.sh ──────────────────────────────────
  cat > "$SRC/env.sh" <<'ENV_EOF'
#!/usr/bin/env bash
# ==============================================================================
# env.sh - RISC-V LLVM 交叉工具链与统一 AI 编译器环境激活脚本
# ==============================================================================
# 使用方式:
#   source env.sh
# ==============================================================================
ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. 导出底层 C/C++ 交叉工具链
TOOLCHAIN_BIN="$ENV_DIR/install-toolchain/bin"
[ -d "$TOOLCHAIN_BIN" ] || TOOLCHAIN_BIN="$ENV_DIR/install-clang-musl/bin"
if [ -d "$TOOLCHAIN_BIN" ]; then
  case ":$PATH:" in
    *":$TOOLCHAIN_BIN:"*) ;;
    *) export PATH="$TOOLCHAIN_BIN:${PATH}" ;;
  esac
fi

# 2. 导出统一 AI 编译器 (MLIR + Torch-MLIR)
AI_BIN="$ENV_DIR/install-ai/bin"
if [ -d "$AI_BIN" ]; then
  case ":$PATH:" in
    *":$AI_BIN:"*) ;;
    *) export PATH="$AI_BIN:${PATH}" ;;
  esac
fi

if [ -d "$ENV_DIR/install-ai/lib" ]; then
  export LD_LIBRARY_PATH="$ENV_DIR/install-ai/lib:${LD_LIBRARY_PATH:-}"
fi

if [ -d "$ENV_DIR/install-ai/python" ]; then
  export PYTHONPATH="$ENV_DIR/install-ai/python:${PYTHONPATH:-}"
fi

echo "  ✓ 已激活 RISC-V LLVM 交叉工具链: $TOOLCHAIN_BIN"
if [ -d "$AI_BIN" ]; then
  echo "  ✓ 已激活统一 AI 编译器 (MLIR + Torch-MLIR): $AI_BIN"
fi
ENV_EOF
  chmod +x "$SRC/env.sh"
  cp -a "$SRC/env.sh" "$INSTALL_TOOLCHAIN/env.sh"

  mark prune
  ok "架构解耦完成：底层工具链 ($INSTALL_TOOLCHAIN) 与统一 AI 编译器 ($INSTALL_AI) 就绪"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_prune
fi
