#!/usr/bin/env bash
# ==============================================================================
# scripts/builtins.sh - 安装基础头文件并编译 compiler-rt builtins
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
init_config

step_builtins() {
  if is_done builtins; then
    ok "compiler-rt builtins 已就绪，跳过"
    return
  fi
  log "准备目标基础头文件并编译 compiler-rt builtins"
  mkdir -p "$SYSROOT/usr/include"
  local hdr_dir
  hdr_dir="$(get_linux_headers_include_dir)"
  [ -d "$hdr_dir" ] || die "缺少 Linux 内核头文件目录: $hdr_dir (请先执行 ./build.sh --step fetch)"
  # 使用 -rL 解除软链接引用，避免因目标 sysroot 已存在实际目录而报 cannot overwrite directory 错误
  cp -rL "$hdr_dir/." "$SYSROOT/usr/include/"

  # 1. 确定用于交叉编译目标运行库的 clang
  local target_clang="$INSTALL/bin/clang"
  local target_clangxx="$INSTALL/bin/clang++"
  local target_ar="$INSTALL/bin/llvm-ar"
  local target_nm="$INSTALL/bin/llvm-nm"
  local target_ranlib="$INSTALL/bin/llvm-ranlib"

  if [ ! -x "$target_clang" ]; then
    target_clang="$BOOT/bin/clang"
    target_clangxx="$BOOT/bin/clang++"
    target_ar="$BOOT/bin/llvm-ar"
    target_nm="$BOOT/bin/llvm-nm"
    target_ranlib="$BOOT/bin/llvm-ranlib"
  fi
  [ -x "$target_clang" ] || die "未找到编译器，请先执行 ./build.sh --step llvm"

  # 2. 安装 musl 基础头文件到 sysroot（只需头文件，几秒钟即可完成）
  echo "  安装 musl 头文件到 $SYSROOT/usr/include ..."
  ( cd "$MUSL_DIR"
    make distclean >/dev/null 2>&1 || true
    CC="$target_clang --target=$T -fuse-ld=lld" \
    ./configure \
        --target="$MUSL_TARGET" \
        --prefix=/usr \
        --syslibdir=/lib \
        --disable-gcc-wrapper
    make DESTDIR="$SYSROOT" install-headers )

  # 3. 独立构建 compiler-rt/lib/builtins
  echo "  独立构建 compiler-rt/lib/builtins ..."
  local RT_BUILD="$SRC/build-compiler-rt"
  mkdir -p "$RT_BUILD"

  "$BOOT/bin/cmake" -G Ninja \
    -S "$LLVM_DIR/compiler-rt/lib/builtins" \
    -B "$RT_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$target_clang" \
    -DCMAKE_CXX_COMPILER="$target_clangxx" \
    -DCMAKE_ASM_COMPILER="$target_clang" \
    -DCMAKE_AR="$target_ar" \
    -DCMAKE_NM="$target_nm" \
    -DCMAKE_RANLIB="$target_ranlib" \
    -DCMAKE_C_COMPILER_TARGET="$T" \
    -DCMAKE_ASM_COMPILER_TARGET="$T" \
    -DCMAKE_SYSROOT="$SYSROOT" \
    -DCMAKE_C_FLAGS="--sysroot=$SYSROOT" \
    -DCMAKE_ASM_FLAGS="--sysroot=$SYSROOT" \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    -DCOMPILER_RT_BAREMETAL_BUILD=ON

  "$BOOT/bin/ninja" -C "$RT_BUILD" -j"$JOBS"

  # 4. 部署 builtins 到 clang 资源目录及 sysroot
  echo "  部署 builtins 到资源目录 ..."
  local clang_ver
  clang_ver=$("$target_clang" -dumpversion 2>/dev/null | cut -d. -f1 || echo "23")
  local inst_res="$INSTALL/lib/clang/$clang_ver/lib/$T"
  mkdir -p "$inst_res" "$SYSROOT/usr/lib" "$SYSROOT/lib"
  cp -a "$RT_BUILD"/lib/linux/"$RT_BUILTIN_NAME" "$inst_res/libclang_rt.builtins.a"
  cp -a "$RT_BUILD"/lib/linux/"$RT_BUILTIN_NAME" "$SYSROOT/usr/lib/libclang_rt.builtins.a"
  cp -a "$RT_BUILD"/lib/linux/"$RT_BUILTIN_NAME" "$inst_res/$RT_BUILTIN_NAME"

  if [ -d "$BOOT/bin" ] && [ -d "$BOOT/$LLVM_PREBUILT" ]; then
    local boot_res="$BOOT/$LLVM_PREBUILT/lib/clang/18/lib/$T"
    mkdir -p "$boot_res"
    cp -a "$RT_BUILD"/lib/linux/"$RT_BUILTIN_NAME" "$boot_res/libclang_rt.builtins.a"
  fi

  mark builtins
  ok "compiler-rt builtins 就绪"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_builtins
fi
