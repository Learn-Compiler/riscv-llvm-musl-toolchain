#!/usr/bin/env bash
# ==============================================================================
# scripts/package.sh - 产物离线归档打包 (tar.zst) 与计算 SHA256 校验和
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
init_config

step_package() {
  log "打包发布"
  local name="${PACKAGE_NAME:-riscv64-unknown-musl-linux}" out
  cd "$SRC"
  [ -d "$INSTALL" ] || die "没有可打包的安装目录: $INSTALL"
  command -v zstd >/dev/null || die "缺少 zstd 压缩工具，请先安装 (如 apt-get install -y zstd)"

  rm -rf "$name" && cp -a "$INSTALL" "$name"
  out="${name}-$(date +%Y%m%d).tar.zst"
  tar -cf - "$name" | zstd -T0 -19 -o "$out"
  rm -rf "$name"
  sha256sum "$out" | tee SHA256SUMS
  ok "发布产物就绪：$SRC/$out"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_package
fi
