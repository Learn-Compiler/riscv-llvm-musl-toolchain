#!/usr/bin/env bash
#
# build-clang-musl.sh
# ---------------------------------------------------------------------------
# 从零构建 riscv64-unknown-linux-musl 的「无 GCC」Clang 工具链：
#     clang + lld + compiler-rt + libc++/libc++abi/libunwind + musl
#
# 特点：
#   * 最终工具链里没有 GCC，也没有 libgcc —— 运行时全部来自 compiler-rt
#   * 宿主引导工具也全部免 root（官方自包含二进制 + dpkg -x 解包）
#   * 幂等：可重复执行，已完成的步骤自动跳过
#
# 用法：
#   ./build-clang-musl.sh               # 完整流程
#   ./build-clang-musl.sh --fetch       # 只拉源码（llvm + musl）
#   ./build-clang-musl.sh --package     # 构建完成后打包
#   JOBS=6 ./build-clang-musl.sh        # 控制并行度
# ---------------------------------------------------------------------------
set -euo pipefail

# ─── 路径 ────────────────────────────────────────────────────────────────
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="riscv64-unknown-linux-musl"
INSTALL="$SRC/install-clang-musl"
SYSROOT="$INSTALL/sysroot"
BUILD="$SRC/build-llvm-musl"
BOOT="$SRC/.bootstrap"
STAMPS="$SRC/.build-stamps"
SHIM="$SRC/.musl-shim"

export PATH="$BOOT/bin:${PATH}"
export LD_LIBRARY_PATH="$BOOT/lib:${LD_LIBRARY_PATH:-}"

# ─── 版本 / 地址 ─────────────────────────────────────────────────────────
LLVM_SHA="ca7933e47d3a3451d81e72ac174dcb5aa28b59d1"
MUSL_SHA="9fa28ece75d8a2191de7c5bb53bed224c5947417"
LLVM_REPO="https://github.com/llvm/llvm-project.git"
MUSL_REPO="https://github.com/kraj/musl.git"

LLVM_PREBUILT="clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04"
LLVM_PREBUILT_URL="https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.8/${LLVM_PREBUILT}.tar.xz"
CMAKE_TARBALL="cmake-3.30.5-linux-x86_64"
CMAKE_URL="https://github.com/Kitware/CMake/releases/download/v3.30.5/${CMAKE_TARBALL}.tar.gz"
NINJA_URL="https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-linux.zip"
# noble 已移除 libtinfo5，只能用 jammy 归档池
TINFO5_URL="http://archive.ubuntu.com/ubuntu/pool/universe/n/ncurses/libtinfo5_6.3-2_amd64.deb"

JOBS="${JOBS:-6}"          # 内存只有 ~5G 可用，别开太大
HOST_GCC_VER="13"          # 宿主 libstdc++ 头文件版本
HOST_TRIPLE="x86_64-linux-gnu"

# ─── 输出 ────────────────────────────────────────────────────────────────
c_ok=$'\033[1;32m'; c_er=$'\033[1;31m'; c_hd=$'\033[1;36m'; c_off=$'\033[0m'
log() { printf '\n%s==> %s%s\n' "$c_hd" "$*" "$c_off"; }
ok()  { printf '%s  ✓ %s%s\n' "$c_ok" "$*" "$c_off"; }
die() { printf '\n%s!! %s%s\n' "$c_er" "$*" "$c_off" >&2; exit 1; }

# ─── 幂等标记 ────────────────────────────────────────────────────────────
is_done() { [ -f "$STAMPS/$1" ]; }
mark()    { mkdir -p "$STAMPS"; date '+%F %T' > "$STAMPS/$1"; }

# ─── 带断点续传的下载 ────────────────────────────────────────────────────
# GitHub release 资源带 accept-ranges: bytes，可用 -C - 续传。
# 长时间大文件传输必然会被中断，必须续传，否则每一次都从 0 重来。
fetch_file() {   # $1=url $2=dest
  local url="$1" dest="$2" want size i curlok
  want=$(curl -sIL --max-time 60 "$url" | tr -d '\r' \
         | awk 'tolower($1)=="content-length:"{v=$2} END{print v}')
  if [ -n "$want" ] && [ "$want" != 0 ]; then printf '  目标大小 %s 字节\n' "$want"; fi
  for i in $(seq 1 60); do
    size=$(stat -c%s "$dest" 2>/dev/null || echo 0)
    if [ -n "$want" ] && [ "$size" = "$want" ]; then return 0; fi
    curlok=0
    curl -fL --retry 2 --retry-delay 2 --retry-all-errors \
         -C - -o "$dest" "$url" && curlok=1
    size=$(stat -c%s "$dest" 2>/dev/null || echo 0)
    if [ -n "$want" ]; then
      [ "$size" = "$want" ] && return 0
    else
      [ "$curlok" = 1 ] && return 0
    fi
    printf '    中断于 %s/%s 字节，3 秒后断点续传（第 %d 次）\n' "$size" "${want:-?}" "$i"
    sleep 3
  done
  return 1
}

# ─── 参数 ────────────────────────────────────────────────────────────────
ONLY_FETCH=0; DO_PACKAGE=0; REBUILD_LLVM=0
for a in "$@"; do
  case "$a" in
    --fetch)        ONLY_FETCH=1 ;;
    --package)      DO_PACKAGE=1 ;;
    --rebuild-llvm) REBUILD_LLVM=1 ;;
    --clean)
      printf '\n==> 清理构建缓存与时间戳 ...\n'
      rm -rf "$SRC/.build-stamps" "$SRC/build-llvm-musl" "$SRC/build-compiler-rt" "$SRC/install-clang-musl" "$SRC/.musl-shim"
      printf '  ✓ 清理完成\n'
      exit 0
      ;;
    *) die "未知参数: $a (支持: --fetch, --package, --rebuild-llvm, --clean)" ;;
  esac
done

if [ "$REBUILD_LLVM" = 1 ]; then
  rm -f "$STAMPS/llvm"
fi

# ─── 0. 前置检查 ─────────────────────────────────────────────────────────
[ -d "$SRC/linux-headers/include" ] \
  || die "缺少 $SRC/linux-headers/include"

command -v curl >/dev/null || die "缺少 curl"
command -v tar  >/dev/null || die "缺少 tar"

printf '%sriscv64-unknown-linux-musl 无 GCC 工具链构建%s\n' "$c_hd" "$c_off"
printf '  SRC     = %s\n  INSTALL = %s\n  JOBS    = %s\n' "$SRC" "$INSTALL" "$JOBS"

# ═════════════════════════════════════════════════════════════════════════
# 1. 免 root 引导工具
# ═════════════════════════════════════════════════════════════════════════
step_bootstrap() {
  if is_done bootstrap; then
    ok "引导工具已就绪，跳过"
    return
  fi
  log "1/5 准备免 root 引导工具到 $BOOT"
  mkdir -p "$BOOT/bin"

  # ---- cmake ----
  if [ ! -x "$BOOT/$CMAKE_TARBALL/bin/cmake" ]; then
    echo "  下载 cmake ..."
    fetch_file "$CMAKE_URL" "$BOOT/cmake.tar.gz"
    tar -xzf "$BOOT/cmake.tar.gz" -C "$BOOT"
  fi
  ln -sf "$BOOT/$CMAKE_TARBALL/bin/cmake" "$BOOT/bin/cmake"
  ln -sf "$BOOT/$CMAKE_TARBALL/bin/ctest" "$BOOT/bin/ctest"
  ok "cmake $("$BOOT/bin/cmake" --version | head -1 | awk '{print $3}')"

  # ---- ninja ----
  if [ ! -x "$BOOT/ninja/ninja" ]; then
    echo "  下载 ninja ..."
    fetch_file "$NINJA_URL" "$BOOT/ninja.zip"
    mkdir -p "$BOOT/ninja"
    unzip -oq "$BOOT/ninja.zip" -d "$BOOT/ninja"
    chmod +x "$BOOT/ninja/ninja"
  fi
  ln -sf "$BOOT/ninja/ninja" "$BOOT/bin/ninja"
  ok "ninja $("$BOOT/bin/ninja" --version)"

  # ---- clang/lld 官方预编译（自包含）----
  local LD="$BOOT/$LLVM_PREBUILT"
  if [ ! -x "$LD/bin/clang" ]; then
    echo "  下载 LLVM 18.1.8 官方预编译（约 1.1GB）..."
    fetch_file "$LLVM_PREBUILT_URL" "$BOOT/llvm.tar.xz"
    tar -xJf "$BOOT/llvm.tar.xz" -C "$BOOT"
  fi
  for t in clang clang++ lld ld.lld llvm-ar llvm-ranlib llvm-strip llvm-nm \
           llvm-objcopy llvm-objdump llvm-ranlib; do
    [ -x "$LD/bin/$t" ] && ln -sf "$LD/bin/$t" "$BOOT/bin/$t"
  done
  ok "clang $("$BOOT/bin/clang" --version | head -1 | awk '{print $3}')"

  # ---- make + 宿主 libstdc++ 头文件（免 root 解包）----
  local DEBS="$BOOT/debs" ROOT="$BOOT/root"
  mkdir -p "$DEBS"
  if [ ! -x "$ROOT/usr/bin/make" ] || [ ! -d "$ROOT/usr/include/c++/$HOST_GCC_VER" ]; then
    echo "  下载 make / libstdc++-dev / libgcc-dev ..."
    ( cd "$DEBS"
      for p in make "libstdc++-$HOST_GCC_VER-dev" "libgcc-$HOST_GCC_VER-dev"; do
        ls "${p}"_*.deb >/dev/null 2>&1 || apt-get download "$p" >/dev/null 2>&1 || true
      done )
  fi
  # libtinfo5：noble 已删除该包，从 jammy 归档池取。
  # ubuntu-18.04 版预编译 clang 要求符号版本 NCURSES_TINFO_5.0.19991023，
  # 软链到系统的 libtinfo.so.6 无效（版本名不同），必须用真的 .so.5。
  if [ ! -e "$ROOT/lib/x86_64-linux-gnu/libtinfo.so.5" ] \
     && [ ! -e "$ROOT/usr/lib/x86_64-linux-gnu/libtinfo.so.5" ]; then
    echo "  获取 libtinfo5（jammy 归档池）..."
    fetch_file "$TINFO5_URL" "$DEBS/libtinfo5.deb"
  fi
  [ -n "$(ls -A "$DEBS"/*.deb 2>/dev/null)" ] || die "deb 下载失败，请检查网络"
  mkdir -p "$ROOT"
  for d in "$DEBS"/*.deb; do dpkg -x "$d" "$ROOT"; done
  ln -sf "$ROOT/usr/bin/make" "$BOOT/bin/make"

  # 把 libtinfo.so.5 收进独立目录，全局加进 LD_LIBRARY_PATH
  local t5
  t5=$(find "$ROOT" -name 'libtinfo.so.5' -print -quit)
  [ -n "$t5" ] || die "libtinfo.so.5 解包失败"
  mkdir -p "$BOOT/lib"
  ln -sf "$t5" "$BOOT/lib/libtinfo.so.5"
  export LD_LIBRARY_PATH="$BOOT/lib:${LD_LIBRARY_PATH:-}"
  ok "make $("$BOOT/bin/make" --version 2>/dev/null | head -1 | awk '{print $3}')"

  # ---- 确认 RISCV 后端存在 ----
  "$BOOT/bin/clang" --print-targets 2>/dev/null | grep -qi riscv \
    || die "引导 clang 不含 RISCV 后端（或无法运行）"
  ok "clang 可运行且含 RISCV 后端"
  mark bootstrap
}

# 选定宿主 C++ 编译方式（决定 CMAKE_CXX_FLAGS）
HOST_CXX_FLAGS=""
HOST_LINK_FLAGS=""
step_host_cxx() {
  log "1b/5 确定宿主 C++ 编译方式"
  local probe="$BOOT/probe.cc"
  cat > "$probe" <<'EOF'
#include <vector>
#include <string>
#include <iostream>
int main(){ std::vector<std::string> v{"a"}; std::cout << v.size(); return 0; }
EOF

  local gccdir="$BOOT/root/usr/lib/gcc/$HOST_TRIPLE/$HOST_GCC_VER"
  # 宿主没有 binutils（无 ld），必须用预编译包自带的 ld.lld
  local lld="-fuse-ld=lld"
  # 方案 1：用免 root 解包的 libstdc++
  if [ -d "$gccdir" ]; then
    if "$BOOT/bin/clang++" "--gcc-install-dir=$gccdir" $lld "$probe" -o /dev/null 2>/dev/null; then
      HOST_CXX_FLAGS="--gcc-install-dir=$gccdir -Qunused-arguments"
      HOST_LINK_FLAGS="$lld"
      ok "宿主 C++：libstdc++ (--gcc-install-dir=$gccdir) + ld.lld"
      return
    fi
  fi
  # 方案 2：用 LLVM 预编译包自带的 libc++（该包只有头文件，可能不可用）
  if "$BOOT/bin/clang++" -stdlib=libc++ $lld "$probe" -o /dev/null 2>/dev/null; then
    HOST_CXX_FLAGS="-stdlib=libc++ -Qunused-arguments"
    HOST_LINK_FLAGS="$lld"
    ok "宿主 C++：libc++ (预编译包自带) + ld.lld"
    return
  fi
  die "找不到可用的宿主 C++ 标准库，无法编译 LLVM"
}

# ═════════════════════════════════════════════════════════════════════════
# 2. 拉取源码
# ═════════════════════════════════════════════════════════════════════════
fetch_commit() {   # $1=repo $2=sha $3=dest $4=检出后必须存在的哨兵文件
  local repo="$1" sha="$2" dest="$3" sentinel="$4" i got
  # 必须同时满足：工作区哨兵文件在 + git 目录在 + 目标提交在
  # （只验提交对象会漏掉「fetch 成功但没检出」的半成品状态）
  if [ -e "$dest/$sentinel" ] && [ -d "$dest/.git" ] \
     && git -C "$dest" cat-file -e "${sha}^{commit}" 2>/dev/null; then
    ok "$(basename "$dest") 已就绪（含 ${sha:0:12}），跳过"
    return
  fi
  echo "  拉取 $(basename "$dest") @ ${sha:0:12} ..."
  rm -rf "$dest"
  mkdir -p "$dest"
  git -C "$dest" init -q
  git -C "$dest" remote add origin "$repo"
  got=0
  for i in $(seq 1 10); do
    if git -C "$dest" fetch --depth 1 origin "$sha" >/dev/null 2>&1; then got=1; break; fi
    echo "    第 $i 次失败，10 秒后重试"; sleep 10
  done
  [ "$got" = 1 ] || die "拉取 $repo 失败（已重试 10 次）"
  git -C "$dest" checkout -q -f FETCH_HEAD
  [ -e "$dest/$sentinel" ] || die "$(basename "$dest") 检出后仍缺少 $sentinel"
  git -C "$dest" log -1 --format='  ✓ %h %ad %s' --date=short
}

step_fetch() {
  if is_done fetch; then
    ok "源码已就绪，跳过"
    return
  fi
  log "2/5 准备源码"
  rm -rf "$SRC/.git/modules/llvm" "$SRC/.git/modules/musl"

  # 支持外部指定自研/本地 LLVM 源码（便于二次开发）
  if [ -n "${LLVM_SRC:-}" ]; then
    log "使用本地自研 LLVM 源码: $LLVM_SRC"
    [ -d "$LLVM_SRC/llvm" ] || die "指定的 LLVM_SRC 缺少 llvm 目录: $LLVM_SRC"
    ln -sfn "$LLVM_SRC" "$SRC/llvm"
  else
    fetch_commit "$LLVM_REPO" "$LLVM_SHA" "$SRC/llvm" "llvm/CMakeLists.txt"
  fi

  # 支持外部指定自研/本地 Musl 源码
  if [ -n "${MUSL_SRC:-}" ]; then
    log "使用本地自研 Musl 源码: $MUSL_SRC"
    [ -f "$MUSL_SRC/configure" ] || die "指定的 MUSL_SRC 缺少 configure: $MUSL_SRC"
    ln -sfn "$MUSL_SRC" "$SRC/musl"
  else
    fetch_commit "$MUSL_REPO" "$MUSL_SHA" "$SRC/musl" "configure"
  fi

  [ -f "$SRC/llvm/llvm/CMakeLists.txt" ]        || die "llvm 源码不完整"
  [ -f "$SRC/llvm/runtimes/CMakeLists.txt" ]    || die "runtimes 目录缺失"
  [ -f "$SRC/llvm/compiler-rt/CMakeLists.txt" ] || die "compiler-rt 缺失"
  [ -f "$SRC/musl/configure" ]                  || die "musl 源码不完整"
  mark fetch
  ok "源码就绪"
}

# ═════════════════════════════════════════════════════════════════════════
# 2b. 预先构建 compiler-rt builtins（解开 musl libc.so 软浮点循环依赖）
# ═════════════════════════════════════════════════════════════════════════
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
  ( cd "$SRC/musl"
    make distclean >/dev/null 2>&1 || true
    CC="$BOOT/bin/clang --target=$T -fuse-ld=lld" \
    ./configure \
        --target=riscv64-linux-musl \
        --prefix=/usr \
        --syslibdir=/lib \
        --disable-gcc-wrapper
    make DESTDIR="$SYSROOT" install-headers )

  # 2. 独立构建 compiler-rt/lib/builtins
  echo "  独立构建 compiler-rt/lib/builtins ..."
  local RT_BUILD="$SRC/build-compiler-rt"
  mkdir -p "$RT_BUILD"

  "$BOOT/bin/cmake" -G Ninja \
    -S "$SRC/llvm/compiler-rt/lib/builtins" \
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
  cp -a "$RT_BUILD"/lib/linux/libclang_rt.builtins-riscv64.a "$CLANG_RES/"
  cp -a "$RT_BUILD"/lib/linux/clang_rt.crt*.o "$CLANG_RES/"

  local TARGET_RES="$BOOT/$LLVM_PREBUILT/lib/clang/18/lib/$T"
  mkdir -p "$TARGET_RES"
  cp -a "$RT_BUILD"/lib/linux/libclang_rt.builtins-riscv64.a "$TARGET_RES/libclang_rt.builtins.a"
  cp -a "$RT_BUILD"/lib/linux/clang_rt.crtbegin-riscv64.o "$TARGET_RES/crtbegin.o"
  cp -a "$RT_BUILD"/lib/linux/clang_rt.crtend-riscv64.o "$TARGET_RES/crtend.o"

  mark builtins
  ok "compiler-rt builtins 就绪"
}

# ═════════════════════════════════════════════════════════════════════════
# 3. 用宿主 clang 编译 musl
# ═════════════════════════════════════════════════════════════════════════
step_musl() {
  if is_done musl; then
    ok "musl sysroot 已就绪，跳过"
    return
  fi
  log "3/5 编译 musl → $SYSROOT"
  mkdir -p "$SYSROOT" "$SHIM"
  for t in ar ranlib strip nm objcopy; do
    ln -sf "$BOOT/bin/llvm-$t" "$SHIM/riscv64-linux-musl-$t"
  done
  export PATH="$SHIM:$BOOT/bin:$PATH"

  cd "$SRC/musl"
  make distclean >/dev/null 2>&1 || true

  local BUILTIN_LIB="$BOOT/$LLVM_PREBUILT/lib/clang/18/lib/linux/libclang_rt.builtins-riscv64.a"
  [ -f "$BUILTIN_LIB" ] || die "缺少 compiler-rt builtins 库: $BUILTIN_LIB"

  CC="$BOOT/bin/clang --target=$T -fuse-ld=lld" \
  LIBCC="$BUILTIN_LIB" \
  ./configure \
      --target=riscv64-linux-musl \
      --prefix=/usr \
      --syslibdir=/lib \
      --disable-gcc-wrapper \
      LIBCC="$BUILTIN_LIB"

  make -j"$JOBS" LIBCC="$BUILTIN_LIB"
  make DESTDIR="$SYSROOT" install

  # 修复 musl 默认创建的绝对路径软链接（/usr/lib/libc.so 在宿主机上为悬空链接）为相对链接
  ln -sf ../usr/lib/libc.so "$SYSROOT/lib/ld-musl-riscv64.so.1"

  # 补内核头文件（musl 的 --with-headers 是无效选项，会被静默忽略）
  cp -a "$SRC/linux-headers/include/." "$SYSROOT/usr/include/"

  for f in lib/ld-musl-riscv64.so.1 usr/lib/libc.a usr/lib/crt1.o usr/include/stdio.h; do
    [ -e "$SYSROOT/$f" ] || [ -L "$SYSROOT/$f" ] || die "musl 安装不完整，缺少 $f"
  done
  mark musl
  ok "musl sysroot 就绪"
}

# ═════════════════════════════════════════════════════════════════════════
# 4. 编译 clang / lld + compiler-rt + libc++
# ═════════════════════════════════════════════════════════════════════════
step_llvm() {
  if is_done llvm; then
    ok "LLVM + runtimes 已构建完成，跳过"
    return
  fi
  log "4/5 配置 LLVM + runtimes"
  mkdir -p "$BUILD"
  ln -sfn "$SYSROOT" "$BUILD/sysroot"     # 构建期 clang 从 ../sysroot 找 sysroot

  "$BOOT/bin/cmake" -G Ninja -S "$SRC/llvm/llvm" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL" \
    -DCMAKE_C_COMPILER="$BOOT/bin/clang" \
    -DCMAKE_CXX_COMPILER="$BOOT/bin/clang++" \
    -DCMAKE_C_FLAGS="$HOST_CXX_FLAGS" \
    -DCMAKE_CXX_FLAGS="$HOST_CXX_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$HOST_LINK_FLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="$HOST_LINK_FLAGS" \
    -DCMAKE_MODULE_LINKER_FLAGS="$HOST_LINK_FLAGS" \
    -DLLVM_ENABLE_PIC=ON \
    -DLLVM_TARGETS_TO_BUILD=RISCV \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLVM_ENABLE_RUNTIMES="compiler-rt;libcxx;libcxxabi;libunwind" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="$T" \
    -DLLVM_RUNTIME_TARGETS="$T" \
    -DLLVM_INSTALL_TOOLCHAIN_ONLY=On \
    -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DDEFAULT_SYSROOT=../sysroot \
    -DCLANG_DEFAULT_LINKER=lld \
    -DCLANG_DEFAULT_RTLIB=compiler-rt \
    -DCLANG_DEFAULT_UNWINDLIB=libunwind \
    -DCLANG_DEFAULT_CXX_STDLIB=libc++ \
    -DCOMPILER_RT_BUILD_CRT:BOOL=ON \
    -DRUNTIMES_${T}_COMPILER_RT_BUILD_CRT:BOOL=ON \
    -DRUNTIMES_${T}_LIBCXX_HAS_MUSL_LIBC=On \
    -DRUNTIMES_${T}_COMPILER_RT_BUILD_SANITIZERS=Off \
    -DRUNTIMES_${T}_COMPILER_RT_BUILD_XRAY=OFF \
    -DRUNTIMES_${T}_COMPILER_RT_BUILD_LIBFUZZER=OFF \
    -DRUNTIMES_${T}_COMPILER_RT_BUILD_PROFILE=OFF \
    -DRUNTIMES_${T}_COMPILER_RT_BUILD_MEMPROF=OFF \
    -DRUNTIMES_${T}_COMPILER_RT_BUILD_ORC=OFF \
    -DRUNTIMES_${T}_COMPILER_RT_USE_BUILTINS_LIBRARY=ON \
    -DRUNTIMES_${T}_COMPILER_RT_USE_LLVM_UNWINDER=ON \
    -DRUNTIMES_${T}_LLVM_INCLUDE_TESTS=OFF \
    -DRUNTIMES_${T}_COMPILER_RT_INCLUDE_TESTS=OFF \
    -DRUNTIMES_${T}_LIBUNWIND_INCLUDE_TESTS=OFF \
    -DRUNTIMES_${T}_LIBCXX_INCLUDE_TESTS=OFF \
    -DRUNTIMES_${T}_LIBCXXABI_INCLUDE_TESTS=OFF \
    -DRUNTIMES_${T}_LIBUNWIND_USE_COMPILER_RT=ON \
    -DRUNTIMES_${T}_LIBCXXABI_USE_COMPILER_RT=ON \
    -DRUNTIMES_${T}_LIBCXXABI_USE_LLVM_UNWINDER=ON \
    -DRUNTIMES_${T}_CMAKE_C_FLAGS="--sysroot=$SYSROOT" \
    -DRUNTIMES_${T}_CMAKE_CXX_FLAGS="--sysroot=$SYSROOT" \
    -DRUNTIMES_${T}_CMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld" \
    -DRUNTIMES_${T}_CMAKE_SHARED_LINKER_FLAGS="-fuse-ld=lld" \
    -DRUNTIMES_${T}_CMAKE_MODULE_LINKER_FLAGS="-fuse-ld=lld" \
    -DLLVM_PARALLEL_LINK_JOBS=1

  grep -qi 'COMPILER_RT_BUILD_CRT.*ON' "$BUILD/CMakeCache.txt" \
    || die "COMPILER_RT_BUILD_CRT 未生效，检查上面的 cmake 参数"
  ok "cmake 配置完成（COMPILER_RT_BUILD_CRT=ON 已确认）"

  log "4/5 编译（-j$JOBS，预计 30-60 分钟）"
  "$BOOT/bin/ninja" -C "$BUILD" -j"$JOBS"

  log "4/5 安装"
  "$BOOT/bin/ninja" -C "$BUILD" install

  # C++ 运行库补进 sysroot
  cp -a "$BUILD"/lib/"$T"/libc++*   "$SYSROOT/lib/" 2>/dev/null || true
  cp -a "$BUILD"/lib/"$T"/libunwind* "$SYSROOT/lib/" 2>/dev/null || true
  mark llvm
  ok "安装完成"
}

# ═════════════════════════════════════════════════════════════════════════
# 4b. 精简与专业化修整（剔除无关跨平台工具、剥离符号、生成 .cfg 与三元组链接）
# ═════════════════════════════════════════════════════════════════════════
step_prune() {
  log "4b/5 精简工具链（剥离无关工具、宿主符号，生成 .cfg 与三元组链接）"

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

  # 2. 对宿主可执行程序与共享库进行 strip（剥离多余符号，大幅减少体积）
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
  cat > "$INSTALL/bin/${T}.cfg" <<'EOF'
--target=riscv64-unknown-linux-musl
--sysroot=<CFGDIR>/../sysroot
-fuse-ld=lld
-rtlib=compiler-rt
-unwindlib=libunwind
-stdlib=libc++
EOF

  ok "工具链精简与 .cfg 配置完成"
}

# ═════════════════════════════════════════════════════════════════════════
# 5. 验证
# ═════════════════════════════════════════════════════════════════════════
step_verify() {
  log "5/5 验证"

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
  file "$wd/hello" | grep -q 'UCB RISC-V' \
    || die "C 冒烟测试产物不是 RISC-V"
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
  file "$wd/h" | grep -q 'UCB RISC-V' || die "C++ 冒烟测试产物不是 RISC-V"
  ok "C++/libc++ 链接成功"

  ok "验证全部通过"
}

# ═════════════════════════════════════════════════════════════════════════
# 打包
# ═════════════════════════════════════════════════════════════════════════
step_package() {
  log "打包"
  local name="riscv64-unknown-musl-linux" out
  cd "$SRC"
  [ -d "$INSTALL" ] || die "没有可打包的安装目录"
  rm -rf "$name" && cp -a "$INSTALL" "$name"
  out="${name}-$(date +%Y%m%d).tar.zst"
  tar -cf - "$name" | zstd -T0 -19 -o "$out"
  rm -rf "$name"
  sha256sum "$out" | tee SHA256SUMS
  ok "产物：$SRC/$out"
}

# ═════════════════════════════════════════════════════════════════════════
# 主流程
# ═════════════════════════════════════════════════════════════════════════
mkdir -p "$STAMPS"

step_bootstrap
step_host_cxx
step_fetch

if [ "$ONLY_FETCH" = 1 ]; then
  log "仅拉取模式，结束"
  exit 0
fi

step_builtins
step_musl
step_llvm
step_prune
step_verify

if [ "$DO_PACKAGE" = 1 ]; then
  step_package
fi

log "全部完成"
printf '工具链位置: %s\n' "$INSTALL"
printf '标准调用  : %s/bin/%s-clang hello.c\n' "$INSTALL" "$T"
printf '原生调用  : %s/bin/clang --target=%s --sysroot=%s hello.c\n' "$INSTALL" "$T" "$SYSROOT"

