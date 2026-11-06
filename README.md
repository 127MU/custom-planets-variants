<p align="center"><img src="assets/cpv.png" width="112" alt="CPV"></p>
<h1 align="center">自定义星球和变种</h1>
<p align="center">Custom Planets & Variants · Rust / Flutter / Morrow</p>
<p align="center"><b>简体中文</b> · <a href="README.en.md">English</a></p>

独立的《绝地潜兵 2》星球与变种方案工具。搜索星球、组合效果、配置作战与分区，在同一个界面保存和管理方案。

## 功能

- **星球方案**：按名称或 ID 搜索，添加、编辑、启用和导入导出方案。
- **效果目录**：中英文搜索、分类筛选、多选、仅显示已选；分类栏支持鼠标拖拽、滚轮和横向滚动条。
- **作战配置**：作战类型、作战数量、敌人阵营、分区初始化及防守参数。城市与特殊星球战役需要足够的作战槽（默认 20）。
- **临时战备**：同一星球可选择多条临时配发战备。游戏内有数量限制，超出时可能无法正常使用。
- **天气预设**：已有依据的异界风暴效果；实验性候选在界面内标注。
- **个性化**：自定义背景图片、中英文切换、浅色 / 深色 / 跟随系统、强调色，以及磨砂、液态玻璃和实色材质。
- **军械库**：按名称、型号或 ID 多选主武器、副武器和投掷物，也可批量预览。方案在游戏重新登录并读取物品目录及库存时应用。缺少目录条目的装备使用同类模板，未命名条目属于实验性预览。配件替换匹配武器已有方案中的原配件。 [物品目录数据](https://github.com/deepseekv41flash/hd2-datamined/blob/master/docs/tables/WEAPON-CUSTOMIZATION-26251122.md) · [解锁总览](https://github.com/deepseekv41flash/hd2-network-proxy/blob/master/docs/UNLOCK-MAP-2026-11-06.md)
- **连接管理**：生成本机证书、确认后加入当前用户信任、Steam 启动桥接和可选上游 HTTP 代理。
- **诊断模式**：检查配置目录、程序完整性、证书和代理状态，导出本地 JSON 日志。

## 安装与使用

需要 Windows 10 / 11，64 位。

1. 单文件版直接运行 **自定义星球和变种.exe**。首次启动会校验并释放运行时，无需自行安装 Qt、Flutter 或 Python。便携 ZIP 版需完整解压后运行同名 EXE。
2. 在「星球方案」添加星球，选择效果、作战与分区参数并保存。
3. 在「连接」生成本机证书。确认用途后点击「安装信任」，在 Windows UAC 中授权后自动安装，仅写入**当前用户**证书库；不会让整个应用长期以管理员身份运行。
4. 复制界面提供的 Steam 启动选项，粘贴到游戏属性 → 通用 → 启动选项。
5. 完全退出游戏，开启代理，然后从 Steam 启动游戏。

关闭代理后请完全重启游戏。没有有效会话时，桥接程序按普通方式启动游戏。软件不会默认开启代理、安装证书、修改系统代理或 hosts，也不安装网络捕获驱动。

### 加速器与上游代理

只处理 `api.live.prod.thehelldiversgame.com` 的必要游戏 API；登录与反作弊连接排除在 HTTPS 解密之外。需要经现有 HTTP 代理访问游戏 API 时，在停止代理后开启对应选项。配置仅影响本程序进程，不修改 Windows 全局代理。

### 诊断与排错

在「设置 → 诊断与日志」开启诊断模式，点击「运行诊断」检查状态，再点击「导出诊断日志」。报告不会自动上传，不含账号、认证头、请求正文、证书私钥或截图。

窗口打不开时，可用命令行启动：

```powershell
& '.\自定义星球和变种.exe' --diagnostic
```

配置默认保存在 `%LOCALAPPDATA%/CPV/RustProfile`，日志位于其 `diagnostics` 子目录。默认目录不可写时尝试 EXE 旁的 `.CPV/Profile`。可用 `CPV_PROFILE` 指定配置目录。

证书安装如被 Windows 策略拒绝，界面会显示系统错误；不要通过全局更改系统信任策略解决。移除信任仅针对本程序记录的证书。


### 自动更新

每次启动都会在后台检查一次正式发行版，有新版时弹窗展示更新日志。GitHub 不可访问时会依次尝试 GH-Proxy 和 GHFast 镜像；弹窗提供原站与两条镜像下载按钮，点击后在默认浏览器下载。设置的“关于”中也可手动检查更新，并查看作者 127MU 与项目地址。软件不会自动运行下载的安装包。

发布新版本时，使用 `tools/release-manifest.py` 生成 `latest.json`，与 EXE 一起上传到同一个正式发行版，镜像更新检测依赖此文件。

## 从源码构建

需要 Rust stable（支持 edition 2024）、Flutter stable、Python 3，以及 Visual Studio 2022 的 C++ 桌面开发组件和 Windows SDK。开发验证使用 Flutter 3.47.9 / Dart 3.13.7。

```powershell
.\tools\build-rust.ps1 -Test
.\tools\build-rust.ps1
cd ui
flutter pub get
flutter analyze
flutter test
flutter build windows --release
cd ..
```

准备基于官方 mitmproxy 的 Windows Python 运行时（`python.exe`、`proxy_main.py`、依赖与 `runtime.json` 文件哈希清单），然后打包：

```powershell
python tools/package-rust.py --output dist/release --proxy-runtime C:/path/to/mitmproxy-runtime --solid-payload build/cpv-payload.xz
.\tools\build-rust.ps1 -Payload build/cpv-payload.xz -PayloadManifest dist/release/CPV_2.0.2/manifest.json
```

启动器输出为 `backend/target/release/cpv-launcher.exe`，可复制并命名为 `自定义星球和变种.exe`。源码不提交 Python 运行时或生成的二进制文件。打包会校验运行时哈希和关键图标字形；出现图标缺失提示时，请先 `flutter clean` 后重新构建。

## 目录

| 目录 | 用途 |
| --- | --- |
| `backend/` | Rust 主机、Steam 桥接与单文件启动器 |
| `ui/` | Flutter 界面与 Morrow 玻璃材质 |
| `proxy/` | 必要游戏 API 的代理插件 |
| `assets/` | 图标与效果目录 |
| `tools/` | 构建、打包与校验脚本 |
| `tests/` | 代理、目录及打包回归检查 |

## 特别鸣谢

- [hd2-network-proxy](https://github.com/deepseekv41flash/hd2-network-proxy) — 网络接口与变种研究。
- [hd2-datamined](https://github.com/deepseekv41flash/hd2-datamined) — 游戏数据结构与资源研究。
- [hd2-srkit](https://github.com/deepseekv41flash/hd2-srkit) — 相关工具与技术资料。
- [Morrow](https://github.com/StarrySky7D4/morrow) — 界面设计参考、玻璃组件与着色器。
- [SHODAN Stat Editor](https://github.com/127MU/SHODAN-Stat-Editor) — 独立工具的项目来源。
- [mitmproxy](https://github.com/mitmproxy/mitmproxy)、Flutter、Rust 及所有相关开源项目。

## 许可

本项目采用 **AGPL-3.0-only**。第三方来源、版本与许可见 [`licenses/`](licenses/)。本项目与游戏官方无关联；目录候选与实验性选项不代表已在所有游戏版本和组合中验证。
