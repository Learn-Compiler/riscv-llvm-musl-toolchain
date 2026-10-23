# ==============================================================================
# Dockerfile - riscv-llvm-musl-toolchain 容器化 100% 可重现构建环境
# ==============================================================================
# 使用方式:
#   docker build -t riscv-llvm-toolchain:latest .
#   docker run --rm -v $(pwd):/workspace riscv-llvm-toolchain:latest ./build.sh --default
# ==============================================================================

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# 安装所有宿主编译工具链与依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    clang \
    lld \
    cmake \
    ninja-build \
    git \
    curl \
    ca-certificates \
    python3 \
    python3-dev \
    zstd \
    file \
    unzip \
    ccache \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# 设置工作目录
WORKDIR /workspace

# 拷贝工具链构建仓库
COPY . /workspace

# 默认构建指令
CMD ["./build.sh", "--default"]
