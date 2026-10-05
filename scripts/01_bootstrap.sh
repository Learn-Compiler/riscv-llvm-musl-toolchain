#!/usr/bin/env bash
# ==============================================================================
# scripts/01_bootstrap.sh - 准备免 root 引导工具与确定宿主 C++ 编译方式
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
init_config

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

  # ---- 确认后端存在 ----
  "$BOOT/bin/clang" --print-targets 2>/dev/null | grep -qi "$LLVM_TARGET_ARCH" \
    || die "引导 clang 不含 $LLVM_TARGET_ARCH 后端（或无法运行）"
  ok "clang 可运行且含 $LLVM_TARGET_ARCH 后端"
  mark bootstrap
}

# 选定宿主 C++ 编译方式（决定 CMAKE_CXX_FLAGS 并持久化至 host_cxx_flags.env）
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
      echo "export HOST_CXX_FLAGS=\"$HOST_CXX_FLAGS\"" > "$BOOT/host_cxx_flags.env"
      echo "export HOST_LINK_FLAGS=\"$HOST_LINK_FLAGS\"" >> "$BOOT/host_cxx_flags.env"
      ok "宿主 C++：libstdc++ (--gcc-install-dir=$gccdir) + ld.lld"
      return
    fi
  fi
  # 方案 2：用 LLVM 预编译包自带的 libc++（该包只有头文件，可能不可用）
  if "$BOOT/bin/clang++" -stdlib=libc++ $lld "$probe" -o /dev/null 2>/dev/null; then
    HOST_CXX_FLAGS="-stdlib=libc++ -Qunused-arguments"
    HOST_LINK_FLAGS="$lld"
    echo "export HOST_CXX_FLAGS=\"$HOST_CXX_FLAGS\"" > "$BOOT/host_cxx_flags.env"
    echo "export HOST_LINK_FLAGS=\"$HOST_LINK_FLAGS\"" >> "$BOOT/host_cxx_flags.env"
    ok "宿主 C++：libc++ (预编译包自带) + ld.lld"
    return
  fi
  die "找不到可用的宿主 C++ 标准库，无法编译 LLVM"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_bootstrap
  step_host_cxx
fi
