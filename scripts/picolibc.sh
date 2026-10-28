#!/usr/bin/env bash
# ==============================================================================
# scripts/picolibc.sh - 交叉编译 Picolibc C 运行库 (支持多 march 矩阵编译)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
init_config

get_target_tools() {
  target_clang="$INSTALL/bin/clang"
  target_ar="$INSTALL/bin/llvm-ar"
  target_as="$INSTALL/bin/llvm-as"
  target_nm="$INSTALL/bin/llvm-nm"
  target_ranlib="$INSTALL/bin/llvm-ranlib"
  target_strip="$INSTALL/bin/llvm-strip"
  [ -x "$target_clang" ] || die "未找到编译器 $target_clang，请先执行 ./build.sh --step llvm"
}

find_meson() {
  local m=""
  if [ -x "$BOOT/bin/meson" ]; then
    m="$BOOT/bin/meson"
  elif command -v meson >/dev/null 2>&1; then
    m="$(command -v meson)"
  elif [ -x "$HOME/.local/bin/meson" ]; then
    m="$HOME/.local/bin/meson"
  fi
  [ -n "$m" ] || die "未找到 meson 构建工具，请先执行: pip install --user meson 或 apt install meson"
  echo "$m"
}

step_picolibc() {
  if is_done picolibc; then
    ok "目标 C 运行库 (Picolibc) 已就绪，跳过"
    return
  fi

  get_target_tools
  local meson_bin
  meson_bin="$(find_meson)"
  local ninja_bin="$BOOT/bin/ninja"
  [ -x "$ninja_bin" ] || ninja_bin="$(command -v ninja || true)"
  [ -n "$ninja_bin" ] || die "未找到 ninja 工具"

  log "使用 LLVM 编译目标 Picolibc C 运行库 (Meson + Ninja, 多 march 矩阵)"
  local BUILD_PICOLIBC="$SRC/build-picolibc"
  mkdir -p "$BUILD_PICOLIBC" "$SYSROOT/lib" "$SYSROOT/include"

  # 1. 生成主 Meson 交叉编译配置 (基于 riscv32-unknown-elf)
  local cross_file="$BUILD_PICOLIBC/cross.ini"
  cat > "$cross_file" <<EOF
[binaries]
c = ['$target_clang', '--target=${TARGET_TRIPLE}', '-nostdlib']
ar = '$target_ar'
as = '$target_as'
nm = '$target_nm'
strip = '$target_strip'
ranlib = '$target_ranlib'

[host_machine]
system = 'unknown'
cpu_family = 'riscv32'
cpu = 'riscv32'
endian = 'little'

[properties]
c_args = ['-fno-common']
skip_sanity_check = true
EOF

  # 2. 配置并编译主 Picolibc (开启 multilib)
  log "配置 Picolibc 主工程 (开启编译器原生 multilib 矩阵)"
  rm -rf "$BUILD_PICOLIBC/build.ninja" "$BUILD_PICOLIBC/meson-private" 2>/dev/null || true

  local extra_args=()
  if [ -n "${PICOLIBC_EXTRA_MESON_ARGS:-}" ]; then
    read -r -a extra_args <<< "${PICOLIBC_EXTRA_MESON_ARGS}"
  fi

  "$meson_bin" setup "$BUILD_PICOLIBC" "$PICOLIBC_SRC" \
    --cross-file "$cross_file" \
    --buildtype=minsize \
    --prefix="$SYSROOT" \
    -Dincludedir=include \
    -Dlibdir=lib \
    -Dsysroot-install=true \
    -Dsystem-libc=true \
    -Dpicocrt=true \
    -Dmultilib=true \
    -Dtests=false \
    "${extra_args[@]}"

  log "编译并安装 Picolibc (-j$JOBS)"
  "$ninja_bin" -C "$BUILD_PICOLIBC" -j"$JOBS" install

  # 3. 编译额外的扩展架构矩阵 (如 double-float ilp32d 与 64 位 lp64/lp64d)
  if [ "${ENABLE_MULTILIB:-ON}" = "ON" ]; then
    log "构建扩展 march 矩阵库 (rv32imafdc/ilp32d, rv64imac/lp64, rv64imafdc/lp64d)"
    local extra_matrix=(
      "rv32imafdc/ilp32d:riscv32-unknown-elf:riscv32:-march=rv32imafdc -mabi=ilp32d"
      "rv64imac/lp64:riscv64-unknown-elf:riscv64:-march=rv64imac -mabi=lp64"
      "rv64imafdc/lp64d:riscv64-unknown-elf:riscv64:-march=rv64imafdc -mabi=lp64d"
    )

    for entry in "${extra_matrix[@]}"; do
      local rel_dir target_trip cpu_fam flags
      rel_dir="$(echo "$entry" | cut -d: -f1)"
      target_trip="$(echo "$entry" | cut -d: -f2)"
      cpu_fam="$(echo "$entry" | cut -d: -f3)"
      flags="$(echo "$entry" | cut -d: -f4)"

      # 若已有对应库文件则跳过
      if [ -f "$SYSROOT/lib/$rel_dir/libc.a" ]; then
        ok "矩阵架构 $rel_dir 目标库已存在，跳过"
        continue
      fi

      log "编译扩展矩阵目标: $rel_dir ($flags)"
      local mdir="$SRC/build-picolibc-${rel_dir//\//_}"
      mkdir -p "$mdir"
      local mcross="$mdir/cross.ini"
      
      # 分解 flags
      local cargs_str="'-fno-common'"
      for f in $flags; do
        cargs_str="$cargs_str, '$f'"
      done

      cat > "$mcross" <<EOF
[binaries]
c = ['$target_clang', '--target=${target_trip}', '-nostdlib']
ar = '$target_ar'
as = '$target_as'
nm = '$target_nm'
strip = '$target_strip'
ranlib = '$target_ranlib'

[host_machine]
system = 'unknown'
cpu_family = '${cpu_fam}'
cpu = '${cpu_fam}'
endian = 'little'

[properties]
c_args = [${cargs_str}]
skip_sanity_check = true
EOF

      "$meson_bin" setup "$mdir" "$PICOLIBC_SRC" \
        --cross-file "$mcross" \
        --buildtype=minsize \
        --prefix="$SYSROOT" \
        -Dincludedir=include \
        -Dlibdir="lib/$rel_dir" \
        -Dsysroot-install=false \
        -Dsystem-libc=false \
        -Dpicocrt=true \
        -Dmultilib=false \
        -Dtests=false >/dev/null

      "$ninja_bin" -C "$mdir" -j"$JOBS" install >/dev/null
      rm -rf "$mdir"
      ok "矩阵目标 $rel_dir 构建完成"
    done
  fi

  # 4. 生成多 march 矩阵的 multilib.yaml 映射清单
  log "生成 Multilib 架构矩阵清单 (multilib.yaml)"
  mkdir -p "$INSTALL/lib/clang-runtimes"
  local yaml_file="$SYSROOT/lib/multilib.yaml"
  cat > "$yaml_file" <<'YAML_EOF'
MultilibVersion: 1.0
Variants:
- Dir: rv32i/ilp32
  Flags: [-march=rv32i, -mabi=ilp32]
- Dir: rv32im/ilp32
  Flags: [-march=rv32im, -mabi=ilp32]
- Dir: rv32iac/ilp32
  Flags: [-march=rv32iac, -mabi=ilp32]
- Dir: .
  Flags: [-march=rv32imac, -mabi=ilp32]
- Dir: rv32imafc/ilp32f
  Flags: [-march=rv32imafc, -mabi=ilp32f]
- Dir: rv32imafdc/ilp32d
  Flags: [-march=rv32imafdc, -mabi=ilp32d]
- Dir: rv64imac/lp64
  Flags: [-march=rv64imac, -mabi=lp64]
- Dir: rv64imafdc/lp64d
  Flags: [-march=rv64imafdc, -mabi=lp64d]

Mappings:
- Match: -march=rv32i.*
  Flags: [-march=rv32i]
- Match: -march=rv32im_.*|-march=rv32im$
  Flags: [-march=rv32im]
- Match: -march=rv32iac.*
  Flags: [-march=rv32iac]
- Match: -march=rv32imac.*
  Flags: [-march=rv32imac]
- Match: -march=rv32imafc.*
  Flags: [-march=rv32imafc]
- Match: -march=rv32gc.*|-march=rv32imafdc.*
  Flags: [-march=rv32imafdc]
- Match: -march=rv64imac.*
  Flags: [-march=rv64imac]
- Match: -march=rv64gc.*|-march=rv64imafdc.*
  Flags: [-march=rv64imafdc]
YAML_EOF
  cp -a "$yaml_file" "$INSTALL/lib/clang-runtimes/multilib.yaml"

  # 5. 确保双向目录兼容软链接 ($SYSROOT/<variant>/lib <-> $SYSROOT/lib/<variant>)
  for v in rv32i/ilp32 rv32im/ilp32 rv32iac/ilp32 rv32imafc/ilp32f rv32imafdc/ilp32d rv64imac/lp64 rv64imafdc/lp64d; do
    if [ -d "$SYSROOT/lib/$v" ]; then
      mkdir -p "$SYSROOT/$(dirname "$v")"
      if [ ! -e "$SYSROOT/$v" ]; then
        mkdir -p "$SYSROOT/$v"
        ln -sfn "../../lib/$v" "$SYSROOT/$v/lib"
      fi
    fi
  done

  mark picolibc
  ok "Picolibc C 运行库与多 march 矩阵部署完成"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_picolibc
fi
