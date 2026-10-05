# riscv-llvm-musl-toolchain

从零构建面向 **RISC-V 64** 的现代、纯净、无 GCC 依赖的 **LLVM + Musl** 交叉编译工具链：
`Clang + LLD + compiler-rt + libc++ + libc++abi + libunwind + Musl libc`

---

## 🌟 项目特性

- **100% 纯 LLVM 生态闭环**：彻底摒弃 GCC、GNU Binutils 和 `libgcc`，所有底座运行时由 `compiler-rt builtins` 和 `libc++` 提供。
- **免 root 宿主自举**：全自动准备独立的 Clang、CMake、Ninja 与必要依赖，不依赖宿主机系统全局开发环境，不污染宿主系统。
- **专为二次开发设计**：支持通过 `LLVM_SRC` 环境变量直接挂载本地自研/二次开发的 LLVM 源码树，支持微调自研指令、调度模型与优化 Pass 并快速迭代。
- **工业级瘦身与裁剪**：自动剔除 Windows、macOS、GPU Offload、Python 静态分析等数十个无关跨平台冗余组件，执行宿主符号剥离（Strip），体积减少 >60%（离线发布包仅 ~100MB）。
- **即开即用（Relocatable & Zero-flags）**：内置 `riscv64-unknown-linux-musl.cfg` 便携配置文件与 15 个标准三元组软链接，无需输入长串 `--target` 和 `--sysroot` 参数。

---

## 🚀 快速开始

### 1. 基础构建（官方发布版本）
克隆本仓库后，直接运行脚本：
```bash
./build.sh
```
构建完成后，工具链将生成在 `install-clang-musl/` 目录下。

### 2. 常用构建选项
```bash
# 构建完成后自动打包为 .tar.zst 离线发布包
./build.sh --package

# 仅拉取源码（llvm 与 musl）
./build.sh --fetch

# 仅重新编译 LLVM 模块（二次开发高频迭代时使用，跳过 builtins/musl 重复构建）
./build.sh --rebuild-llvm

# 单步独立调试执行（支持: bootstrap, fetch, builtins, musl, llvm, prune, verify, package）
./build.sh --step musl
./build.sh --step verify

# 从指定阶段开始向下连续执行（例如跳过 fetch 直接从 builtins 开始）
./build.sh --from llvm

# 指定目标平台配置（默认使用 config/targets/riscv64-linux-musl.env）
./build.sh --target riscv64-linux-musl

# 清理所有构建缓存与时间戳
./build.sh --clean

# 控制构建并行度（默认 JOBS=6）
JOBS=8 ./build.sh
```

---

## 🛠️ LLVM 二次开发与平滑升级指南

本工具链构建系统采用**构建编排（Builder）与 LLVM 源码完全解耦**的架构，便于长期的芯片定制开发与上游版本升级。

### 1. 使用本地自研/定制 LLVM 源码构建
如果您在本地维护了包含自研指令集（Custom Extension）或修改过的 LLVM 源码库：
```bash
LLVM_SRC=/path/to/your/custom-llvm-project ./build.sh
```
`build.sh` 会自动检测并挂载您的本地 LLVM 源码树进行编译，产出包含您自定义特性的专属工具链。

### 2. 日常二次开发工作流
1. 在您的 `custom-llvm-project` 中修改代码（例如 TableGen `.td` 指令定义、ISel 匹配规则、指令调度模型或自定义 Pass）；
2. 运行快速重编命令验证工具链与冒烟测试：
   ```bash
   LLVM_SRC=/path/to/your/custom-llvm-project ./build.sh --rebuild-llvm
   ```
3. 直接使用生成的编译器编译目标程序并验证向量/指令生成。

### 3. 如何跟进官方 LLVM 版本升级
当上游 LLVM 发布新大版本（例如 18 -> 19 -> 20）时：
1. **源码同步**：在您的自研 `llvm-project` 仓库中直接拉取并变基：
   ```bash
   git fetch upstream
   git rebase upstream/release/20.x
   ```
   只需专注于解决纯代码层面的冲突，构建系统不受任何干扰。
2. **更新脚本配置**：如需升级默认拉取的官方版本，只需在 `build.sh` 中修改 `LLVM_SHA` 变量为上游的目标 commit 哈希即可。

---

## 💻 工具链使用示例

把工具链 `bin` 目录加入环境变量，或直接绝对路径调用：

### 1. 编译 C 语言程序
```bash
riscv64-unknown-linux-musl-clang hello.c -o hello
```

### 2. 编译 C++ 语言程序
```bash
riscv64-unknown-linux-musl-clang++ main.cpp -o main
```

### 3. 静态编译完全自包含二进制
```bash
riscv64-unknown-linux-musl-clang -static hello.c -o hello-static
```

### 4. 启用 RISC-V 向量扩展（RVV / Vector）
```bash
riscv64-unknown-linux-musl-clang -march=rv64gcv rvv_app.c -o rvv_app
```

---

## 📂 仓库结构

```text
riscv-llvm-musl-toolchain/
├── build.sh                      # 【主入口】参数解析、环境加载、流水线编排调度
│
├── config/                       # 【配置层】纯声明式环境与目标配置
│   ├── default.env               # 全局通用配置（版本、依赖 URL、编译线程）
│   ├── local.env.example         # 用户本地配置模板（可自由覆盖变量且被 Git 忽略）
│   └── targets/                  # 目标平台配置目录
│       └── riscv64-linux-musl.env# RISC-V 64 Musl 专属平台参数
│
├── third_party/                  # 【第三方子模组】Git Submodules
│   ├── llvm/                     # LLVM 项目源码 (Git Submodule @ release/20.x)
│   └── musl/                     # Musl C 库源码 (Git Submodule @ master)
│
├── scripts/                      # 【执行层】模块化独立步骤流水线
│   ├── common.sh                 # 公共基础设施（日志、时间戳打标、断点续传下载、Git 克隆）
│   ├── 01_bootstrap.sh           # 阶段 1：免 root 准备引导工具 & 探测宿主 C++
│   ├── 02_fetch.sh               # 阶段 2：准备源码 (Submodule 更新或挂载本地源码) 并自动应用补丁
│   ├── 03_builtins.sh            # 阶段 3：安装 Musl 基础头文件并编译 compiler-rt builtins
│   ├── 04_musl.sh                # 阶段 4：配置并构建 Musl libc 并安装至 Sysroot
│   ├── 05_llvm.sh                # 阶段 5：全量编译 LLVM/Clang 及全部运行时
│   ├── 06_prune.sh               # 阶段 6：精简裁剪、Strip、三元组软链接与生成 .cfg 配置文件
│   ├── 07_verify.sh              # 阶段 7：构建产物验证与 C/C++ 冒烟测试
│   └── 08_package.sh             # 阶段 8：打包发布 (tar.zst) 与计算 SHA256 校验和
│
├── patches/                      # 【拓展层】组件补丁目录（自动检测应用）
│   ├── llvm/                     # LLVM 自定义补丁 (*.patch)
│   └── musl/                     # Musl 自定义补丁 (*.patch)
│
├── linux-headers/                # Linux 内核头文件（系统调用与 POSIX 基础）
├── .gitmodules                   # Git Submodule 配置声明
├── .gitignore                    # 忽略构建缓存与本地配置
└── README.md                     # 架构与使用文档
```
