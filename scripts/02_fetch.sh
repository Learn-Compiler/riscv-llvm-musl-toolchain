#!/usr/bin/env bash
# ==============================================================================
# scripts/02_fetch.sh - 准备源码（Git Submodule 初始化检出 / 挂载本地自研源码并应用补丁）
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
init_config

apply_patches() {
  local component="$1" target_dir="$2"
  local patch_dir="$SRC/patches/$component"
  if [ -d "$patch_dir" ] && compgen -G "$patch_dir/*.patch" > /dev/null; then
    echo "  检查并应用 $component 补丁 ..."
    for p in "$patch_dir"/*.patch; do
      [ -f "$p" ] || continue
      local p_name
      p_name="$(basename "$p")"
      if [ -f "$target_dir/.applied_$p_name" ]; then
        ok "补丁 $p_name 已应用，跳过"
      else
        echo "  正在应用补丁: $p_name"
        ( cd "$target_dir" && ( git apply "$p" 2>/dev/null || patch -p1 < "$p" ) ) \
          || die "应用补丁 $p 失败"
        touch "$target_dir/.applied_$p_name"
        ok "补丁 $p_name 应用完成"
      fi
    done
  fi
}

step_fetch() {
  if is_done fetch; then
    ok "源码已就绪，跳过"
    return
  fi
  log "2/5 准备源码 (Submodule / 本地源码)"

  # ---- 1. 准备 LLVM 源码 ----
  if [ -n "${LLVM_SRC:-}" ]; then
    log "使用本地自研 LLVM 源码: $LLVM_SRC"
    [ -d "$LLVM_SRC/llvm" ] || die "指定的 LLVM_SRC 缺少 llvm 目录: $LLVM_SRC"
    mkdir -p "$(dirname "$LLVM_DIR")"
    ln -sfn "$LLVM_SRC" "$LLVM_DIR"
  else
    if [ ! -d "$LLVM_DIR/.git" ] && [ ! -f "$LLVM_DIR/.git" ]; then
      echo "  初始化并检出 llvm 子模组 ..."
      git -C "$SRC" submodule update --init --depth 1 third_party/llvm || \
        git -C "$SRC" submodule update --init third_party/llvm
    fi

    # 若指定了自定义版本，执行版本切换
    if [ -n "${LLVM_VERSION:-}" ]; then
      local llvm_target_ref="$LLVM_VERSION"
      if [[ "$llvm_target_ref" =~ ^[0-9]+$ ]]; then
        llvm_target_ref="release/${llvm_target_ref}.x"
      elif [[ "$llvm_target_ref" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        llvm_target_ref="llvmorg-${llvm_target_ref}"
      fi
      log "检出 LLVM 指定版本/分支: $llvm_target_ref (源参数: $LLVM_VERSION)"
      if ! git -C "$LLVM_DIR" checkout -q -f "$llvm_target_ref" 2>/dev/null; then
        echo "  本地未找到 $llvm_target_ref，正在向上游拉取 ..."
        git -C "$LLVM_DIR" fetch --depth 1 origin "$llvm_target_ref" 2>/dev/null || \
          git -C "$LLVM_DIR" fetch origin "$llvm_target_ref" 2>/dev/null || \
          git -C "$LLVM_DIR" fetch --tags --depth 1 origin 2>/dev/null || true
        git -C "$LLVM_DIR" checkout -q -f "$llvm_target_ref" 2>/dev/null || \
          git -C "$LLVM_DIR" checkout -q -f "FETCH_HEAD" 2>/dev/null || \
          die "切换 LLVM 至 $llvm_target_ref 失败"
      fi
    fi
    ok "llvm 源码已就绪 ($(git -C "$LLVM_DIR" rev-parse --short HEAD 2>/dev/null || echo 'local'))"
  fi

  # ---- 2. 准备 Musl 源码 ----
  if [ -n "${MUSL_SRC:-}" ]; then
    log "使用本地自研 Musl 源码: $MUSL_SRC"
    [ -f "$MUSL_SRC/configure" ] || die "指定的 MUSL_SRC 缺少 configure: $MUSL_SRC"
    mkdir -p "$(dirname "$MUSL_DIR")"
    ln -sfn "$MUSL_SRC" "$MUSL_DIR"
  else
    if [ ! -d "$MUSL_DIR/.git" ] && [ ! -f "$MUSL_DIR/.git" ]; then
      echo "  初始化并检出 musl 子模组 ..."
      git -C "$SRC" submodule update --init --depth 1 third_party/musl || \
        git -C "$SRC" submodule update --init third_party/musl
    fi

    # 若指定了自定义版本，执行版本切换
    if [ -n "${MUSL_VERSION:-}" ]; then
      local musl_target_ref="$MUSL_VERSION"
      if [[ "$musl_target_ref" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        musl_target_ref="v${musl_target_ref}"
      fi
      log "检出 Musl 指定版本/分支: $musl_target_ref (源参数: $MUSL_VERSION)"
      if ! git -C "$MUSL_DIR" checkout -q -f "$musl_target_ref" 2>/dev/null; then
        echo "  本地未找到 $musl_target_ref，正在向上游拉取 ..."
        git -C "$MUSL_DIR" fetch --depth 1 origin "$musl_target_ref" 2>/dev/null || \
          git -C "$MUSL_DIR" fetch origin "$musl_target_ref" 2>/dev/null || \
          git -C "$MUSL_DIR" fetch --tags --depth 1 origin 2>/dev/null || true
        git -C "$MUSL_DIR" checkout -q -f "$musl_target_ref" 2>/dev/null || \
          git -C "$MUSL_DIR" checkout -q -f "FETCH_HEAD" 2>/dev/null || \
          die "切换 Musl 至 $musl_target_ref 失败"
      fi
    fi
    ok "musl 源码已就绪 ($(git -C "$MUSL_DIR" rev-parse --short HEAD 2>/dev/null || echo 'local'))"
  fi

  # ---- 3. 应用拓展补丁 ----
  apply_patches "llvm" "$LLVM_DIR"
  apply_patches "musl" "$MUSL_DIR"

  # ---- 4. 源码完整性校验 ----
  [ -f "$LLVM_DIR/llvm/CMakeLists.txt" ]        || die "llvm 源码不完整: $LLVM_DIR/llvm/CMakeLists.txt"
  [ -f "$LLVM_DIR/runtimes/CMakeLists.txt" ]    || die "runtimes 目录缺失: $LLVM_DIR/runtimes/CMakeLists.txt"
  [ -f "$LLVM_DIR/compiler-rt/CMakeLists.txt" ] || die "compiler-rt 缺失: $LLVM_DIR/compiler-rt/CMakeLists.txt"
  [ -f "$MUSL_DIR/configure" ]                  || die "musl 源码不完整: $MUSL_DIR/configure"

  mark fetch
  ok "源码就绪"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_fetch
fi
