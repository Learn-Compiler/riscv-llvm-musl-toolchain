#!/usr/bin/env bash
# ==============================================================================
# scripts/prune.sh - 工具链净化瘦身、三元组软链接与便携 .cfg 配置
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
init_config

step_prune() {
  log "开始执行 LLVM Baremetal ELF 工具链净化与配置"

  INSTALL_TOOLCHAIN="${INSTALL_TOOLCHAIN:-$INSTALL}"
  [ -d "$INSTALL_TOOLCHAIN/bin" ] || die "未找到安装目录 $INSTALL_TOOLCHAIN/bin，请先完成构建"

  # ─── 1. 深度修整底层工具链：剔除无关测试与宿主内部工具 ────────
  log "净化工具链目录 ($INSTALL_TOOLCHAIN)"
  local useless_bins=(
    scan-build scan-build-py scan-view analyze-build intercept-build hmaptool git-clang-format
    UnicodeNameMappingGenerator yaml-bench llvm-PerfectShuffle verify-uselistorder
    split-file FileCheck count not reduce-chunk-list llvm-stress llvm-test-mustache-spec
    sancov sanstats llvm-c-test clang-cl llvm-ml llvm-ml64 llvm-windres llvm-rc
    llvm-libtool-darwin llvm-dlltool llvm-cvtres llvm-install-name-tool llvm-otool
    ld64.lld wasm-ld lld-link amdgpu-arch nvptx-arch offload-arch clang-nvlink-wrapper
    clang-offload-bundler clang-offload-packager llvm-offload-binary llvm-offload-wrapper
    llvm-gpu-loader clang-repl clang-check clang-extdef-mapping clang-installapi
    clang-refactor clang-scan-deps diagtool dsymutil lli lli-child-target llubi llvm-bcanalyzer
    llvm-bitcode-strip llvm-cas llvm-cat llvm-cfi-verify llvm-cgdata llvm-ctxprof-util
    llvm-cxxdump llvm-cxxmap llvm-debuginfo-analyzer llvm-debuginfod llvm-debuginfod-find
    llvm-diff llvm-dwp llvm-exegesis llvm-extract-bundle-entry llvm-ifs llvm-ir2vec
    llvm-jitlink llvm-jitlink-executor llvm-lib llvm-lipo llvm-lto llvm-lto2 llvm-mca
    llvm-modextract llvm-mt llvm-opt-report llvm-pdbutil llvm-profdata llvm-profgen
    llvm-readtapi llvm-reduce llvm-remarkutil llvm-rtdyld llvm-sim llvm-tli-checker
    llvm-undname llvm-xray obj2yaml yaml2obj
    clang-linker-wrapper llvm-dwarfutil llvm-split llvm-gsymutil
  )

  for b in "${useless_bins[@]}"; do
    rm -f "$INSTALL_TOOLCHAIN/bin/$b"
  done

  # ─── 2. 宿主程序剥离符号 (Strip) ─────────────────────────────────────
  local do_strip=0
  case "${STRIP_SYMBOLS:-AUTO}" in
    ON|on|1)   do_strip=1 ;;
    OFF|off|0) do_strip=0 ;;
    AUTO|auto)
      [ "$BUILD_TYPE" = "Release" ] && do_strip=1 || do_strip=0
      ;;
  esac

  if [ "$do_strip" = 1 ]; then
    log "剥离宿主可执行程序符号 (Release 模式)"
    local host_strip
    host_strip="$(which strip 2>/dev/null || true)"
    if [ -x "$host_strip" ]; then
      for f in "$INSTALL_TOOLCHAIN/bin"/*; do
        if [ -f "$f" ] && [ ! -L "$f" ] && file "$f" | grep -q "ELF.*executable"; then
          "$host_strip" --strip-unneeded "$f" 2>/dev/null || true
        fi
      done
    fi
  fi

  # ─── 3. 生成目标平台标准三元组软链接 (默认 riscv32-unknown-elf) ─────
  log "配置三元组调用入口: 默认 riscv32-unknown-elf，riscv64-unknown-elf 软链接至 riscv32"
  
  # 工具映射列表
  local tools_map=(
    "clang:clang"
    "clang++:clang++"
    "ld:ld.lld"
    "ar:llvm-ar"
    "as:llvm-as"
    "nm:llvm-nm"
    "objcopy:llvm-objcopy"
    "objdump:llvm-objdump"
    "ranlib:llvm-ranlib"
    "readelf:llvm-readelf"
    "size:llvm-size"
    "strings:llvm-strings"
    "strip:llvm-strip"
  )

  # 1) 创建 riscv32-unknown-elf-* 工具链接
  for item in "${tools_map[@]}"; do
    local alias_name="${item%%:*}"
    local real_bin="${item##*:}"
    if [ -x "$INSTALL_TOOLCHAIN/bin/$real_bin" ]; then
      ln -sfn "$real_bin" "$INSTALL_TOOLCHAIN/bin/riscv32-unknown-elf-$alias_name"
      ln -sfn "riscv32-unknown-elf-$alias_name" "$INSTALL_TOOLCHAIN/bin/riscv32-$alias_name"
    fi
  done

  # 2) 创建 riscv64-unknown-elf-* 作为指向 riscv32-unknown-elf-* 的软链接 (按要求)
  for item in "${tools_map[@]}"; do
    local alias_name="${item%%:*}"
    if [ -e "$INSTALL_TOOLCHAIN/bin/riscv32-unknown-elf-$alias_name" ]; then
      ln -sfn "riscv32-unknown-elf-$alias_name" "$INSTALL_TOOLCHAIN/bin/riscv64-unknown-elf-$alias_name"
      ln -sfn "riscv64-unknown-elf-$alias_name" "$INSTALL_TOOLCHAIN/bin/riscv64-$alias_name"
    fi
  done

  # 3) 根目录下的架构软链接映射
  #    $INSTALL/riscv32-unknown-elf -> sysroot
  #    $INSTALL/riscv64-unknown-elf -> riscv32-unknown-elf (软链接)
  if [ -d "$SYSROOT" ]; then
    ln -sfn sysroot "$INSTALL_TOOLCHAIN/riscv32-unknown-elf"
    ln -sfn riscv32-unknown-elf "$INSTALL_TOOLCHAIN/riscv64-unknown-elf"
  fi

  # ─── 4. 生成 Clang 自动装载的 .cfg 配置文件 ────────────────────────
  local cfg_sysroot_rel
  cfg_sysroot_rel="$(basename "$SYSROOT")"

  # 主 clang.cfg (默认 32 位裸机 ELF)
  cat > "$INSTALL_TOOLCHAIN/bin/clang.cfg" <<EOF
--target=riscv32-unknown-elf
--sysroot=<CFGDIR>/../${cfg_sysroot_rel}
-march=rv32imac -mabi=ilp32
-fuse-ld=lld
-rtlib=compiler-rt
-T <CFGDIR>/../${cfg_sysroot_rel}/lib/picolibc.ld
-Wno-unused-command-line-argument
EOF

  if [ -n "${TARGET_EXTRA_CFLAGS:-}" ]; then
    echo "${TARGET_EXTRA_CFLAGS}" >> "$INSTALL_TOOLCHAIN/bin/clang.cfg"
  fi

  ln -sfn clang.cfg "$INSTALL_TOOLCHAIN/bin/clang++.cfg"

  # riscv32-unknown-elf.cfg
  cat > "$INSTALL_TOOLCHAIN/bin/riscv32-unknown-elf.cfg" <<EOF
--target=riscv32-unknown-elf
--sysroot=<CFGDIR>/../${cfg_sysroot_rel}
-march=rv32imac -mabi=ilp32
-fuse-ld=lld
-rtlib=compiler-rt
-T <CFGDIR>/../${cfg_sysroot_rel}/lib/picolibc.ld
-Wno-unused-command-line-argument
EOF
  ln -sfn riscv32-unknown-elf.cfg "$INSTALL_TOOLCHAIN/bin/riscv32.cfg"
  ln -sfn riscv32-unknown-elf.cfg "$INSTALL_TOOLCHAIN/bin/riscv32-elf.cfg"
  ln -sfn riscv32-unknown-elf.cfg "$INSTALL_TOOLCHAIN/bin/riscv32-unknown-elf-clang.cfg"
  ln -sfn riscv32-unknown-elf.cfg "$INSTALL_TOOLCHAIN/bin/riscv32-unknown-unknown-elf-clang.cfg"
  ln -sfn riscv32-unknown-elf.cfg "$INSTALL_TOOLCHAIN/bin/riscv32-unknown-unknown-elf.cfg"

  # riscv64-unknown-elf.cfg (支持 64 位三元组直接调用)
  cat > "$INSTALL_TOOLCHAIN/bin/riscv64-unknown-elf.cfg" <<EOF
--target=riscv64-unknown-elf
--sysroot=<CFGDIR>/../${cfg_sysroot_rel}
-march=rv64imafdc -mabi=lp64d
-fuse-ld=lld
-rtlib=compiler-rt
-T <CFGDIR>/../${cfg_sysroot_rel}/lib/picolibc.ld
-Wno-unused-command-line-argument
EOF
  ln -sfn riscv64-unknown-elf.cfg "$INSTALL_TOOLCHAIN/bin/riscv64.cfg"
  ln -sfn riscv64-unknown-elf.cfg "$INSTALL_TOOLCHAIN/bin/riscv64-elf.cfg"
  ln -sfn riscv64-unknown-elf.cfg "$INSTALL_TOOLCHAIN/bin/riscv64-unknown-elf-clang.cfg"
  ln -sfn riscv64-unknown-elf.cfg "$INSTALL_TOOLCHAIN/bin/riscv64-unknown-unknown-elf-clang.cfg"
  ln -sfn riscv64-unknown-elf.cfg "$INSTALL_TOOLCHAIN/bin/riscv64-unknown-unknown-elf.cfg"

  # ─── 5. 生成统一环境激活脚本 env.sh ──────────────────────────────────
  cat > "$SRC/env.sh" <<'ENV_EOF'
#!/usr/bin/env bash
# ==============================================================================
# env.sh - RISC-V LLVM Baremetal ELF 交叉工具链环境激活脚本
# ==============================================================================
# 使用方式:
#   source env.sh
# ==============================================================================
ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN_BIN="$ENV_DIR/install-toolchain/bin"

if [ -d "$TOOLCHAIN_BIN" ]; then
  case ":$PATH:" in
    *":$TOOLCHAIN_BIN:"*) ;;
    *) export PATH="$TOOLCHAIN_BIN:${PATH}" ;;
  esac
fi

echo "  ✓ 已激活 RISC-V LLVM Baremetal ELF 交叉工具链: $TOOLCHAIN_BIN"
echo "  ✓ 默认目标: riscv32-unknown-elf (riscv64-unknown-elf 为其软链接)"
echo "  ✓ 支持多 march 矩阵编译 (rv32i, rv32im, rv32iac, rv32imac, rv32imafc, rv32imafdc, rv64imac, rv64imafdc)"
ENV_EOF
  chmod +x "$SRC/env.sh"
  cp -a "$SRC/env.sh" "$INSTALL_TOOLCHAIN/env.sh"

  mark prune
  ok "工具链架构修整完成，默认 riscv32-unknown-elf 与软链接就绪"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_prune
fi
