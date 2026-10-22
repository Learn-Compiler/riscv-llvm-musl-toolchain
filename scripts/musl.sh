#!/usr/bin/env bash
# ==============================================================================
# scripts/musl.sh - 使用编译好的 Clang 编译并安装 Musl libc 到 Sysroot
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

  local target_clang="$INSTALL/bin/clang"
  local target_ar="$INSTALL/bin/llvm-ar"
  local target_ranlib="$INSTALL/bin/llvm-ranlib"
  local target_strip="$INSTALL/bin/llvm-strip"
  local target_nm="$INSTALL/bin/llvm-nm"
  local target_objcopy="$INSTALL/bin/llvm-objcopy"

  if [ ! -x "$target_clang" ]; then
    target_clang="$BOOT/bin/clang"
    target_ar="$BOOT/bin/llvm-ar"
    target_ranlib="$BOOT/bin/llvm-ranlib"
    target_strip="$BOOT/bin/llvm-strip"
    target_nm="$BOOT/bin/llvm-nm"
    target_objcopy="$BOOT/bin/llvm-objcopy"
  fi
  [ -x "$target_clang" ] || die "未找到编译器，请先执行 ./build.sh --step llvm"

  ln -sf "$target_ar" "$SHIM/${MUSL_TARGET}-ar"
  ln -sf "$target_ranlib" "$SHIM/${MUSL_TARGET}-ranlib"
  ln -sf "$target_strip" "$SHIM/${MUSL_TARGET}-strip"
  ln -sf "$target_nm" "$SHIM/${MUSL_TARGET}-nm"
  ln -sf "$target_objcopy" "$SHIM/${MUSL_TARGET}-objcopy"
  export PATH="$SHIM:$BOOT/bin:$PATH"

  cd "$MUSL_DIR"
  make distclean >/dev/null 2>&1 || true

  local clang_ver
  clang_ver=$("$target_clang" -dumpversion 2>/dev/null | cut -d. -f1 || echo "23")
  local BUILTIN_LIB=""
  for b in "$INSTALL/lib/clang/$clang_ver/lib/$T/libclang_rt.builtins.a" \
           "$INSTALL/lib/clang/$clang_ver/lib/$T/$RT_BUILTIN_NAME" \
           "$SYSROOT/usr/lib/libclang_rt.builtins.a" \
           "$BOOT/$LLVM_PREBUILT/lib/clang/18/lib/linux/$RT_BUILTIN_NAME"; do
    if [ -f "$b" ]; then BUILTIN_LIB="$b"; break; fi
  done
  [ -n "$BUILTIN_LIB" ] || die "缺少 compiler-rt builtins 库，请先执行 ./build.sh --step builtins"

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

  CC="$target_clang --target=$T -fuse-ld=lld" \
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
    ln -sf ../usr/lib/libc.so "$SYSROOT/lib/$LD_MUSL_SO"
  fi

  # 补内核头文件
  local hdr_dir
  hdr_dir="$(get_linux_headers_include_dir)"
  [ -d "$hdr_dir" ] || die "缺少 Linux 内核头文件目录: $hdr_dir"
  cp -rL "$hdr_dir/." "$SYSROOT/usr/include/"

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
