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
  log "2b/5 准备目标基础头文件并编译 compiler-rt builtins"
  mkdir -p "$SYSROOT/usr/include"
  cp -a "$SRC/linux-headers/include/." "$SYSROOT/usr/include/"

  # 1. 安装 musl 基础头文件到 sysroot（只需头文件，几秒钟即可完成）
  echo "  安装 musl 头文件到 $SYSROOT/usr/include ..."
  ( cd "$MUSL_DIR"
    make distclean >/dev/null 2>&1 || true
    CC="$BOOT/bin/clang --target=$T -fuse-ld=lld" \
    ./configure \
        --target="$MUSL_TARGET" \
        --prefix=/usr \
        --syslibdir=/lib \
        --disable-gcc-wrapper
    make DESTDIR="$SYSROOT" install-headers )

  # 2. 独立构建 compiler-rt/lib/builtins
  echo "  独立构建 compiler-rt/lib/builtins ..."
  local RT_BUILD="$SRC/build-compiler-rt"
  mkdir -p "$RT_BUILD"

  "$BOOT/bin/cmake" -G Ninja \
    -S "$LLVM_DIR/compiler-rt/lib/builtins" \
    -B "$RT_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$BOOT/bin/clang" \
    -DCMAKE_CXX_COMPILER="$BOOT/bin/clang++" \
    -DCMAKE_ASM_COMPILER="$BOOT/bin/clang" \
    -DCMAKE_AR="$BOOT/bin/llvm-ar" \
    -DCMAKE_NM="$BOOT/bin/llvm-nm" \
    -DCMAKE_RANLIB="$BOOT/bin/llvm-ranlib" \
    -DCMAKE_C_COMPILER_TARGET="$T" \
    -DCMAKE_ASM_COMPILER_TARGET="$T" \
    -DCMAKE_SYSROOT="$SYSROOT" \
    -DCMAKE_C_FLAGS="--sysroot=$SYSROOT" \
    -DCMAKE_ASM_FLAGS="--sysroot=$SYSROOT" \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    -DCOMPILER_RT_BAREMETAL_BUILD=ON

  "$BOOT/bin/ninja" -C "$RT_BUILD" -j"$JOBS"

  # 3. 将 builtins 和 crt 部署到引导 clang 的资源目录
  echo "  部署 builtins 到引导 clang 资源目录 ..."
  local CLANG_RES="$BOOT/$LLVM_PREBUILT/lib/clang/18/lib/linux"
  mkdir -p "$CLANG_RES"
  cp -a "$RT_BUILD"/lib/linux/"$RT_BUILTIN_NAME" "$CLANG_RES/"
  cp -a "$RT_BUILD"/lib/linux/clang_rt.crt*.o "$CLANG_RES/"

  local TARGET_RES="$BOOT/$LLVM_PREBUILT/lib/clang/18/lib/$T"
  mkdir -p "$TARGET_RES"
  cp -a "$RT_BUILD"/lib/linux/"$RT_BUILTIN_NAME" "$TARGET_RES/libclang_rt.builtins.a"
  cp -a "$RT_BUILD"/lib/linux/"$RT_CRT_BEGIN" "$TARGET_RES/crtbegin.o"
  cp -a "$RT_BUILD"/lib/linux/"$RT_CRT_END" "$TARGET_RES/crtend.o"

  mark builtins
  ok "compiler-rt builtins 就绪"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_builtins
fi
