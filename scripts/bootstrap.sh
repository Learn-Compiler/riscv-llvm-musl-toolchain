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

# 带版本回退的查找：先找精确名字，再依次找 <name>-<N>。
# 例如 clang -> clang-21 … clang-5，gcc -> gcc-14 … gcc-5。
# Ubuntu/Debian 的 clang-N 包通常只提供版本化名字，没有 /usr/bin/clang。
find_system_binary_versioned() {
  local name="$1" max="${2:-30}" min="${3:-5}" v p
  if p="$(find_system_binary "$name")"; then echo "$p"; return 0; fi
  for (( v=max; v>=min; v-- )); do
    if p="$(find_system_binary "${name}-${v}")"; then echo "$p"; return 0; fi
  done
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

  # ---- 4. 宿主 C/C++ 编译器 (优先本地，支持 clang-17 / gcc-13 这类版本化名字) ----
  local sys_cc="" sys_cxx=""
  local f_clang f_clangxx f_gcc f_gxx
  f_clang="$(find_system_binary_versioned clang 30 5 || true)"
  f_clangxx="$(find_system_binary_versioned clang++ 30 5 || true)"
  f_gcc="$(find_system_binary_versioned gcc 30 5 || true)"
  f_gxx="$(find_system_binary_versioned g++ 30 5 || true)"

  if [ -n "$f_clang" ] && [ -n "$f_clangxx" ]; then
    sys_cc="$f_clang"
    sys_cxx="$f_clangxx"
    ok "检测到宿主 Clang 编译器: $("$sys_cxx" --version | head -1) [$sys_cxx]"
  elif [ -n "$f_gcc" ] && [ -n "$f_gxx" ]; then
    sys_cc="$f_gcc"
    sys_cxx="$f_gxx"
    ok "检测到宿主 GCC 编译器: $("$sys_cxx" --version | head -1) [$sys_cxx]"
  else
    die "未检测到宿主 C/C++ 编译器 (clang / clang-N / gcc / gcc-N)
    请先安装基础编译工具，例如 Ubuntu：
        sudo apt-get install -y build-essential clang"
  fi

  # 记录编译器家族（clang 与 gcc 接受的参数不同），供 step_host_cxx 使用
  local ccver family
  ccver="$("$sys_cc" --version 2>/dev/null | head -1 || true)"
  case "$ccver" in
    *[Cc]lang*) family="clang" ;;
    *)          family="gcc" ;;
  esac
  export HOST_CC_FAMILY="$family"
  printf 'export HOST_CC_FAMILY="%s"\n' "$HOST_CC_FAMILY" > "$BOOT/host_cc_family.env"
  ok "宿主编译器家族: $HOST_CC_FAMILY"

  ln -sf "$sys_cc" "$BOOT/bin/clang"
  ln -sf "$sys_cxx" "$BOOT/bin/clang++"
  local sys_lld
  sys_lld="$(find_system_binary_versioned ld.lld 30 5 \
             || find_system_binary_versioned lld 30 5 || true)"
  if [ -n "$sys_lld" ]; then
    ln -sf "$sys_lld" "$BOOT/bin/ld.lld"
    ln -sf "$sys_lld" "$BOOT/bin/lld"
  fi
  for t in ar ranlib strip nm objcopy; do
    local sys_tool
    sys_tool="$(find_system_binary_versioned "llvm-$t" 30 5 \
                || find_system_binary_versioned "$t" 30 5 || true)"
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

  # ---- 6. meson (Picolibc 交叉编译依赖) ----
  local sys_meson
  sys_meson="$(find_system_binary meson || true)"
  if [ -z "$sys_meson" ] && [ -x "$HOME/.local/bin/meson" ]; then
    sys_meson="$HOME/.local/bin/meson"
  fi
  if [ -n "$sys_meson" ]; then
    ln -sf "$sys_meson" "$BOOT/bin/meson"
    ok "使用 meson ($("$sys_meson" --version))"
  else
    if command -v python3 >/dev/null 2>&1; then
      log "检测到未安装 meson，尝试通过 pip 引导安装..."
      python3 -m pip install --break-system-packages --user meson >/dev/null 2>&1 || python3 -m pip install --user meson >/dev/null 2>&1 || true
      if [ -x "$HOME/.local/bin/meson" ]; then
        ln -sf "$HOME/.local/bin/meson" "$BOOT/bin/meson"
        ok "成功安装并接入 meson ($("$HOME/.local/bin/meson" --version))"
      fi
    fi
    if [ ! -x "$BOOT/bin/meson" ]; then
      warn "未检测到 meson，picolibc 构建阶段需要 meson (请运行: pip install --user meson 或 apt install -y meson)"
    fi
  fi

  mark bootstrap
}

# 选定宿主 C++ 编译方式（决定 CMAKE_CXX_FLAGS 并持久化至 host_cxx_flags.env）
# 支持单独执行本步骤：缺少引导环境时给出明确指引，而不是「probe.cc 没有那个文件」
step_host_cxx() {
  log "确定宿主 C++ 编译方式"

  # 单独执行时 $BOOT 可能还不存在，先建目录，否则下面的重定向直接失败
  mkdir -p "$BOOT"

  # 复用 step_bootstrap 记录的编译器家族
  if [ -f "$BOOT/host_cc_family.env" ]; then
    # shellcheck disable=SC1090
    source "$BOOT/host_cc_family.env"
  fi

  if [ ! -x "$BOOT/bin/clang++" ]; then
    die "缺少引导 C++ 编译器（$BOOT/bin/clang++）
    引导环境尚未准备。请先执行 bootstrap 步骤：
        ./build.sh --step bootstrap
    或直接跑完整流程：
        ./build.sh"
  fi

  local probe="$BOOT/probe.cc"
  cat > "$probe" <<'PROBE_EOF'
#include <vector>
#include <string>
#include <iostream>
int main(){ std::vector<std::string> v{"a"}; std::cout << v.size(); return 0; }
PROBE_EOF

  # -Qunused-arguments 只有 clang 认识，gcc 传了会直接报错。
  # 这里做能力探测而不是按名字猜，clang / gcc / 其它都能正确适配。
  local fam_flags=""
  # shellcheck disable=SC2086
  if "$BOOT/bin/clang++" -Qunused-arguments -c "$probe" -o /dev/null >/dev/null 2>&1; then
    fam_flags="-Qunused-arguments"
  fi

  local lld_flag=""
  if [ -x "$BOOT/bin/ld.lld" ]; then
    lld_flag="-fuse-ld=lld"
  fi

  local cc_desc
  cc_desc="$("$BOOT/bin/clang++" --version 2>/dev/null | head -1 || true)"

  # shellcheck disable=SC2086
  if "$BOOT/bin/clang++" $lld_flag $fam_flags "$probe" -o /dev/null 2>/dev/null; then
    HOST_CXX_FLAGS="$fam_flags"
    HOST_LINK_FLAGS="$lld_flag"
    printf 'export HOST_CXX_FLAGS="%s"\n'  "$HOST_CXX_FLAGS"  >  "$BOOT/host_cxx_flags.env"
    printf 'export HOST_LINK_FLAGS="%s"\n' "$HOST_LINK_FLAGS" >> "$BOOT/host_cxx_flags.env"
    ok "宿主 C++：$cc_desc${lld_flag:+（链接器 ld.lld）}"
    return
  fi

  # shellcheck disable=SC2086
  if "$BOOT/bin/clang++" $fam_flags "$probe" -o /dev/null 2>/dev/null; then
    HOST_CXX_FLAGS="$fam_flags"
    HOST_LINK_FLAGS=""
    printf 'export HOST_CXX_FLAGS="%s"\n'  "$HOST_CXX_FLAGS"  >  "$BOOT/host_cxx_flags.env"
    printf 'export HOST_LINK_FLAGS="%s"\n' "$HOST_LINK_FLAGS" >> "$BOOT/host_cxx_flags.env"
    ok "宿主 C++：$cc_desc（系统默认链接器）"
    return
  fi

  die "宿主 C++ 编译器无法编译基础测试程序（$cc_desc）
    请检查宿主 C++ 标准库是否完整，例如 Ubuntu：
        sudo apt-get install -y build-essential"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_bootstrap
  step_host_cxx
fi
