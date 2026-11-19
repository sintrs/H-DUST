# Horizon · UOS 20 (glibc 2.28) 构建仓库

这个仓库不含 Horizon 的源码，只放**构建脚本**和一个 **GitHub Actions workflow**，
用来在 Debian 10（glibc 2.28）容器里编译 Horizon 的 Linux 二进制。

## 为什么需要它

Horizon 官方发布的 Linux 包全部在 `ubuntu-22.04` 上编译，二进制里写死了
`GLIBC_2.34` / `GLIBC_2.35` 的符号引用。统信 UOS 20 是 glibc 2.28，`ld.so`
在 `main()` 之前就会拒绝加载（`version 'GLIBC_2.35' not found`，退出码 1，无任何输出）。
AppImage 也一样——它故意不打包 glibc，必须用系统的那份。

符号版本是链接期写进 ELF 的，改不了、补不了，**只能在老环境里重新编译**。

## 怎么用

1. 打开 Actions → 左侧 `Build Linux for glibc 2.28 (UOS 20 / Debian 10)` → `Run workflow`
2. 参数默认即可：源码 `gerdaroot/Horizon-Offline-Launcher`（已含离线改动），
   目标 `both`，CPU 基线 `baseline`（若要 AVX2 可改 `x86-64-v3`，兆芯 KX-7000 支持）
3. 跑完（约 30–60 分钟）在本次运行的 **Artifacts** 里下载 `horizon-glibc228-baseline.zip`
4. 解压得到 `horizon-launcher` / `horizon-client` / `horizon-prepare` / `horizon-server`

## 装到 UOS 20 上

```bash
# 在 UOS 上，把版本目录装进启动器的数据目录
bash tools/ci/install-version-offline.sh ~/下载/horizon-linux-x86_64 nightly
HORIZON_LAUNCHER_NO_SELF_UPDATE=1 horizon-launcher
```

第一次进世界前，资源要就地导出（需要 Java 25，JRE 即可）：

```bash
cd ~/.local/share/horizon-launcher/versions/nightly
./horizon-prepare --prepare --server-jar /路径/26.3-server.jar
```

## 文件

| 文件 | 作用 |
|---|---|
| `tools/ci/Dockerfile.glibc228` | debian:10 + rustup + 6 个开发包 |
| `tools/ci/build-glibc228.sh` | 建镜像 → 编译 → 校验符号版本（`launcher` / `game` / `client`） |
| `tools/ci/verify-glibc.sh` | 校验 `GLIBC_x.y` 上限、数 AVX-512 指令、列 NEEDED 库 |
| `tools/ci/swap-228-package.sh` | 把自编二进制换进官方包解压目录（备份 `*.orig-235`） |
| `tools/ci/install-version-offline.sh` | 在目标机上装版本目录 + 校验 glibc |
| `.github/workflows/build-uos20.yml` | 手动触发的构建 workflow |

## 说明

- 产物只解决 **glibc** 这一关。能否真正渲染出世界，还取决于显卡驱动（UOS 上需要 Vulkan 1.0+ 或 OpenGL 4.x）。
- `horizon-ctl` 不在公开仓库的 workspace 里（上游用私有 runner 编），所以编不出来，
  它会跟着官方包一起被带来，保持 2.34。它只影响控制台/AI 相关功能，不影响启动和进世界。
- `horizon-prepare` / `horizon-server` 若因缺少构建期资源编译失败，workflow 会跳过它们而不是报错，
  这时请留用官方包里的版本（但它们是 2.34，在 UOS 上跑不了——这是已知的遗留问题）。
