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

fetch_and_checkout_ref() {
  local dir="$1" ref="$2" raw_ver="$3" comp_name="$4" repo_url="$5"

  # 1. 尝试直接本地检出（若本地已有该分支/标签/Commit）
  if git -C "$dir" checkout -q -f "$ref" 2>/dev/null; then
    ok "$comp_name 已就绪并检出至本地已有版本: $ref"
    return 0
  fi

  echo "  本地未缓存 $ref，正在向上游仓库精确拉取 ($repo_url) ..."

  # 2. 依次尝试浅拉取候选匹配 (分支、标签、原始命名)
  local fetched=0
  for candidate in "$ref" "refs/heads/$ref" "refs/tags/$ref"; do
    if git -C "$dir" fetch --depth 1 origin "$candidate" >/dev/null 2>&1; then
      fetched=1
      break
    fi
  done

  # 3. 若针对标签的单点浅拉取失败，尝试浅拉取 tags
  if [ "$fetched" = 0 ]; then
    if git -C "$dir" fetch --tags --depth 1 origin "$ref" >/dev/null 2>&1 || \
       git -C "$dir" fetch --tags --depth 1 origin >/dev/null 2>&1; then
      fetched=1
    fi
  fi

  # 4. 执行检出
  if [ "$fetched" = 1 ]; then
    if git -C "$dir" checkout -q -f "$ref" 2>/dev/null || \
       git -C "$dir" checkout -q -f "FETCH_HEAD" 2>/dev/null; then
      ok "$comp_name 已成功自上游拉取并检出至: $ref"
      return 0
    fi
  fi

  # 5. 若均失败，输出清晰的排查引导
  warn "未能自上游 $repo_url 检出 $comp_name 版本 '$ref' (用户输入: '$raw_ver')"
  echo "  排查建议与说明:"
  echo "    1. 命名规范:"
  if [ "$comp_name" = "llvm" ]; then
    echo "       - 主版本分支: release/20.x, release/19.x, main"
    echo "       - 官方发布标签: llvmorg-19.1.0, llvmorg-18.1.8"
    echo "       - 亦可直接传入完整 Git Commit SHA (如 ca7933e...)"
  else
    echo "       - 官方分支: master"
    echo "       - 官方发布标签: v1.2.5, v1.2.4"
  fi
  echo "    2. 浅克隆说明: 本地 submodule 为 --depth 1，默认不含全量历史 tag；拉取需要网络访问 GitHub"
  echo "    3. 免网络方案: 若本地磁盘已有源码，可直接使用: --${comp_name}-src /path/to/source"
  die "获取 $comp_name 版本 '$ref' 失败"
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
      log "检出 LLVM 指定版本: $llvm_target_ref (源参数: $LLVM_VERSION)"
      fetch_and_checkout_ref "$LLVM_DIR" "$llvm_target_ref" "$LLVM_VERSION" "llvm" "$LLVM_REPO"
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
      log "检出 Musl 指定版本: $musl_target_ref (源参数: $MUSL_VERSION)"
      fetch_and_checkout_ref "$MUSL_DIR" "$musl_target_ref" "$MUSL_VERSION" "musl" "$MUSL_REPO"
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
