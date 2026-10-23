#!/usr/bin/env bash
# ==============================================================================
# scripts/bootstrap.sh - 探测并准备宿主引导工具链（本地优先策略）
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
init_config

find_system_binary() {
  local name="$1"
  local p
  while IFS= read -r p; do
    if [[ "$p" != "$BOOT"* ]] && [ -x "$p" ]; then
      echo "$p"
      return 0
    fi
  done < <(which -a "$name" 2>/dev/null || true)
  return 1
}

step_bootstrap() {
  if is_done bootstrap; then
    ok "引导工具已就绪，跳过"
    return
  fi
  log "准备引导工具到 $BOOT (优先检测宿主本地工具链)"
  mkdir -p "$BOOT/bin"
  find "$BOOT/bin" -xtype l -delete 2>/dev/null || true

  # ---- 1. cmake (优先本地 >= 3.20) ----
  local sys_cmake
  sys_cmake="$(find_system_binary cmake || true)"
  if [ -n "$sys_cmake" ]; then
    local cmake_ver
    cmake_ver="$("$sys_cmake" --version | head -1 | awk '{print $3}')"
    local cmake_major cmake_minor
    cmake_major="$(echo "$cmake_ver" | cut -d. -f1)"
    cmake_minor="$(echo "$cmake_ver" | cut -d. -f2)"
    if [ "$cmake_major" -gt 3 ] || { [ "$cmake_major" -eq 3 ] && [ "$cmake_minor" -ge 20 ]; }; then
      ln -sf "$sys_cmake" "$BOOT/bin/cmake"
      local sys_ctest
      sys_ctest="$(find_system_binary ctest || true)"
      [ -n "$sys_ctest" ] && ln -sf "$sys_ctest" "$BOOT/bin/ctest"
      ok "使用宿主本地 cmake ($cmake_ver)"
    fi
  fi
  if [ ! -x "$BOOT/bin/cmake" ]; then
    if [ ! -x "$BOOT/$CMAKE_TARBALL/bin/cmake" ]; then
      echo "  未检测到符合要求的宿主 cmake (需 >= 3.20)，从网络下载 cmake ..."
      fetch_file "$CMAKE_URL" "$BOOT/cmake.tar.gz"
      tar -xzf "$BOOT/cmake.tar.gz" -C "$BOOT"
    fi
    ln -sf "$BOOT/$CMAKE_TARBALL/bin/cmake" "$BOOT/bin/cmake"
    ln -sf "$BOOT/$CMAKE_TARBALL/bin/ctest" "$BOOT/bin/ctest"
    ok "下载引导 cmake $("$BOOT/bin/cmake" --version | head -1 | awk '{print $3}')"
  fi

  # ---- 2. ninja (优先本地) ----
  local sys_ninja
  sys_ninja="$(find_system_binary ninja || find_system_binary ninja-build || true)"
  if [ -n "$sys_ninja" ]; then
    ln -sf "$sys_ninja" "$BOOT/bin/ninja"
    ok "使用宿主本地 ninja ($("$sys_ninja" --version))"
  else
    if [ ! -x "$BOOT/ninja/ninja" ]; then
      echo "  未检测到宿主 ninja，从网络下载 ninja ..."
      fetch_file "$NINJA_URL" "$BOOT/ninja.zip"
      mkdir -p "$BOOT/ninja"
      unzip -oq "$BOOT/ninja.zip" -d "$BOOT/ninja"
      chmod +x "$BOOT/ninja/ninja"
    fi
    ln -sf "$BOOT/ninja/ninja" "$BOOT/bin/ninja"
    ok "下载引导 ninja $("$BOOT/bin/ninja" --version)"
  fi

  # ---- 3. make (优先本地) ----
  local sys_make
  sys_make="$(find_system_binary make || true)"
  if [ -n "$sys_make" ]; then
    ln -sf "$sys_make" "$BOOT/bin/make"
    ok "使用宿主本地 make ($("$sys_make" --version | head -1 | awk '{print $3}'))"
  else
    die "未检测到 make，请先安装 make (如 apt install -y make)"
  fi

  # ---- 4. 宿主 C/C++ 编译器 (优先本地) ----
  local sys_cc="" sys_cxx=""
  local f_clang f_clangxx f_gcc f_gxx
  f_clang="$(find_system_binary clang || true)"
  f_clangxx="$(find_system_binary clang++ || true)"
  f_gcc="$(find_system_binary gcc || true)"
  f_gxx="$(find_system_binary g++ || true)"

  if [ -n "$f_clang" ] && [ -n "$f_clangxx" ]; then
    sys_cc="$f_clang"
    sys_cxx="$f_clangxx"
    ok "检测到宿主 Clang 编译器: $("$sys_cxx" --version | head -1)"
  elif [ -n "$f_gcc" ] && [ -n "$f_gxx" ]; then
    sys_cc="$f_gcc"
    sys_cxx="$f_gxx"
    ok "检测到宿主 GCC 编译器: $("$sys_cxx" --version | head -1)"
  else
    die "未检测到宿主 C/C++ 编译器 (clang/gcc)，请先安装基础编译工具 (如 apt-get install -y build-essential clang)"
  fi

  ln -sf "$sys_cc" "$BOOT/bin/clang"
  ln -sf "$sys_cxx" "$BOOT/bin/clang++"
  local sys_lld
  sys_lld="$(find_system_binary ld.lld || find_system_binary lld || true)"
  if [ -n "$sys_lld" ]; then
    ln -sf "$sys_lld" "$BOOT/bin/ld.lld"
    ln -sf "$sys_lld" "$BOOT/bin/lld"
  fi
  for t in ar ranlib strip nm objcopy; do
    local sys_tool
    sys_tool="$(find_system_binary "llvm-$t" || find_system_binary "$t" || true)"
    if [ -n "$sys_tool" ]; then
      ln -sf "$sys_tool" "$BOOT/bin/llvm-$t"
    fi
  done
  ok "宿主本地编译器与构建工具已接入引导环境"

  # ---- 5. ccache (可选编译加速工具) ----
  local sys_ccache
  sys_ccache="$(find_system_binary ccache || true)"
  if [ -n "$sys_ccache" ]; then
    ln -sf "$sys_ccache" "$BOOT/bin/ccache"
    ok "使用宿主本地 ccache ($("$sys_ccache" --version | head -1))"
  elif [ "${ENABLE_CCACHE:-AUTO}" = "ON" ]; then
    if [ ! -x "$BOOT/$CCACHE_TARBALL/ccache" ]; then
      echo "  显式启用了 ccache 但宿主未安装，从网络下载 ccache ..."
      fetch_file "$CCACHE_URL" "$BOOT/ccache.tar.xz"
      tar -xf "$BOOT/ccache.tar.xz" -C "$BOOT"
    fi
    ln -sf "$BOOT/$CCACHE_TARBALL/ccache" "$BOOT/bin/ccache"
    ok "下载引导 ccache $("$BOOT/bin/ccache" --version | head -1)"
  fi

  mark bootstrap
}

# 选定宿主 C++ 编译方式（决定 CMAKE_CXX_FLAGS 并持久化至 host_cxx_flags.env）
step_host_cxx() {
  log "确定宿主 C++ 编译方式"
  local probe="$BOOT/probe.cc"
  cat > "$probe" <<'PROBE_EOF'
#include <vector>
#include <string>
#include <iostream>
int main(){ std::vector<std::string> v{"a"}; std::cout << v.size(); return 0; }
PROBE_EOF

  local lld_flag=""
  if [ -x "$BOOT/bin/ld.lld" ]; then
    lld_flag="-fuse-ld=lld"
  fi

  if "$BOOT/bin/clang++" $lld_flag "$probe" -o /dev/null 2>/dev/null; then
    HOST_CXX_FLAGS="-Qunused-arguments"
    HOST_LINK_FLAGS="$lld_flag"
    echo "export HOST_CXX_FLAGS=\"$HOST_CXX_FLAGS\"" > "$BOOT/host_cxx_flags.env"
    echo "export HOST_LINK_FLAGS=\"$HOST_LINK_FLAGS\"" >> "$BOOT/host_cxx_flags.env"
    ok "宿主 C++：本地工具链正常工作 ($("$BOOT/bin/clang++" --version | head -1))"
    return
  fi
  if "$BOOT/bin/clang++" "$probe" -o /dev/null 2>/dev/null; then
    HOST_CXX_FLAGS="-Qunused-arguments"
    HOST_LINK_FLAGS=""
    echo "export HOST_CXX_FLAGS=\"$HOST_CXX_FLAGS\"" > "$BOOT/host_cxx_flags.env"
    echo "export HOST_LINK_FLAGS=\"$HOST_LINK_FLAGS\"" >> "$BOOT/host_cxx_flags.env"
    ok "宿主 C++：本地工具链正常工作"
    return
  fi

  die "宿主 C++ 编译器无法编译基础测试程序，请检查宿主开发环境与 C++ 标准库"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_bootstrap
  step_host_cxx
fi
