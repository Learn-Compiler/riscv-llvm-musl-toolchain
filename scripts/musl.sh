#!/usr/bin/env bash
# ==============================================================================
# scripts/musl.sh - 使用宿主引导 Clang 编译并安装 Musl libc 到 Sysroot
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
init_config

step_musl() {
  if is_done musl; then
    ok "musl sysroot 已就绪，跳过"
    return
  fi
  log "编译 musl → $SYSROOT"
  mkdir -p "$SYSROOT" "$SHIM"
  for t in ar ranlib strip nm objcopy; do
    ln -sf "$BOOT/bin/llvm-$t" "$SHIM/${MUSL_TARGET}-$t"
  done
  export PATH="$SHIM:$BOOT/bin:$PATH"

  cd "$MUSL_DIR"
  make distclean >/dev/null 2>&1 || true

  local BUILTIN_LIB="$BOOT/$LLVM_PREBUILT/lib/clang/18/lib/linux/$RT_BUILTIN_NAME"
  [ -f "$BUILTIN_LIB" ] || die "缺少 compiler-rt builtins 库: $BUILTIN_LIB"

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

  CC="$BOOT/bin/clang --target=$T -fuse-ld=lld" \
  LIBCC="$BUILTIN_LIB" \
  ./configure \
      --target="$MUSL_TARGET" \
      --prefix=/usr \
      --syslibdir=/lib \
      --disable-gcc-wrapper \
      --enable-static \
      "${musl_shared_flags[@]}" \
      "${musl_extra_flags[@]}" \
      LIBCC="$BUILTIN_LIB"

  make -j"$JOBS" LIBCC="$BUILTIN_LIB"
  make DESTDIR="$SYSROOT" install

  if [ "${ENABLE_SHARED:-OFF}" = "ON" ]; then
    # 修复 musl 默认创建的绝对路径软链接（/usr/lib/libc.so 在宿主机上为悬空链接）为相对链接
    ln -sf ../usr/lib/libc.so "$SYSROOT/lib/$LD_MUSL_SO"
  fi

  # 补内核头文件（musl 的 --with-headers 是无效选项，会被静默忽略）
  local hdr_dir
  hdr_dir="$(get_linux_headers_include_dir)"
  [ -d "$hdr_dir" ] || die "缺少 Linux 内核头文件目录: $hdr_dir"
  cp -a "$hdr_dir/." "$SYSROOT/usr/include/"

  local check_files=(usr/lib/libc.a usr/lib/crt1.o usr/include/stdio.h)
  if [ "${ENABLE_SHARED:-OFF}" = "ON" ]; then
    check_files=("lib/$LD_MUSL_SO" "${check_files[@]}")
  fi

  for f in "${check_files[@]}"; do
    [ -e "$SYSROOT/$f" ] || [ -L "$SYSROOT/$f" ] || die "musl 安装不完整，缺少 $f"
  done
  mark musl
  ok "musl sysroot 就绪"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_musl
fi
