# Retools

<img src="Host/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="88" height="88" alt="Retools 图标">

Retools 是一款原生 SwiftUI iOS 工具，集成 IPA 管理、设备端签名与续签、LiveContainer 应用容器、设备工具和应用砸壳。

当前版本 **0.1.0 (51)**。基础 Bundle ID 为 `dev.retools.ios`，最低支持 iOS / iPadOS 17.0。部分设备功能需要更新的系统、开发签名或额外授权。

## 功能

| 功能 | 说明 |
| --- | --- |
| IPA 应用库 | 从「文件」、分享入口或 AltStore / SideStore 格式的软件源导入，查看元数据、管理原包并导出签名副本。 |
| 签名与插件 | 导入 P12 和描述文件，校验证书、私钥、权限与有效期；编辑签名配置，导入 `.dylib` / `.deb` 插件并配置加载顺序。 |
| Apple ID 与续签 | 管理多个开发账号和团队，为应用指定签名账号；经配对设备服务安装、续签，也可准备 Retools 自身的开发签名。 |
| 应用容器 | 基于 LiveContainer 运行兼容的 arm64 应用，提供多个数据空间、免 JIT / JIT 模式和悬浮切换侧栏。 |
| 应用砸壳 | 登录商店账号，搜索应用或选择本机应用作为下载目标；下载带许可的加密 IPA，生成独立助手，在真机解密、校验并导出结果。也支持导入包含匹配许可的加密 IPA。 |
| 设备工具 | 查看设备、应用、描述文件和进程，浏览可访问的应用文件，提供开发者定位模拟、进程操作及注销（重启桌面）。 |
| 本机文件访问 | 可选的 worse_query 只读文件入口，沿用应用文件浏览界面；需要兼容系统及实际可用的专用 App Group。 |
| AI 对话 | 默认关闭；支持 OpenAI 兼容和 Anthropic 接口、模型选择、文件与图片附件，记录保存在本地。 |
| 快捷指令 | 提供续签全部应用、安装 IPA 等原生动作。 |

## 构建与安装

### 开发环境

- macOS 与 Xcode 27 或更新版本，包含 iOS 27 SDK。
- XcodeGen 2.42 或更新版本、Python 3。
- Apple Silicon Mac：当前预编译运行库提供 iOS arm64 和 arm64 模拟器切片。
- 生成自签名参考包或重建测试夹具时，需要 Homebrew OpenSSL 3。

仓库包含常规 Xcode 构建所需的预编译 XCFramework，日常构建无需先编译 Rust、Go 或 Unicorn。

```sh
git clone https://github.com/Reukix/retools.git
cd retools
xcodegen generate
open Retools.xcodeproj
```

在 Xcode 中选择 `Retools` scheme。模拟器可直接运行；真机需在 Signing & Capabilities 中选择自己的开发团队，并为主应用和扩展配置匹配的签名。

模拟器中的设备工具使用示例数据，不执行真机系统操作、worse_query 或 FairPlay 解密。

### 生成 IPA

```sh
bash Scripts/build-ipa.sh
```

脚本构建 arm64 Release，检查应用包，输出到 `Artifacts/`：

- `Retools-0.1.0-unsigned.ipa`：未签名原包。
- ad-hoc 参考包及使用占位描述文件的自签名包，供外部签名工具处理。

这些参考包仍需经过设备认可的签名才能安装。构建产物、个人证书及设备备份不提交到仓库。

### 重建底层组件

修改对应源码后，再重建相应 XCFramework：

```sh
# Apple ID 签名及配对桥接：需要 Rust 工具链与两个 iOS target
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
bash Scripts/build-apple-signing.sh

# 商店引擎：需要 Go 1.26.5+、CMake、Ninja 与 Xcode 命令行工具
python3 Scripts/build-store-engine.py
```

版本、来源和本地适配见 [依赖说明](Docs/DEPENDENCIES.md)。

## 真机使用

### 签名、续签与设备连接

1. 在设置中导入自己的 P12 / 描述文件，或登录开发用 Apple ID 并选择团队。
2. 安装、调试和设备工具需要有效的设备配对及可用的回环连接。iOS 27 可使用系统确认配对；其他情况可导入已有配对文件，并按界面配置外部回环代理。
3. 定位模拟、进程管理与容器 JIT 等功能还需要开发者模式及开发者镜像。首次准备镜像需要联网。
4. 在应用签名页面配置证书、应用信息和插件后导出；启用设备连接后，也可安装和续签。

自动续签受系统后台调度、账号状态、签名有效期和设备连接影响。当前项目不内置 VPN 回环代理。

### 容器

在应用详情中选择导入容器，再进入容器页面启动。容器需要未加密、包含 arm64 可执行文件的 IPA。

- **免 JIT**：需要与宿主匹配的开发签名及运行证书，启动前会实际签名并加载测试库。
- **JIT**：需要可用的调试连接，并为将要运行的进程启用 JIT。
- 宿主需要描述文件实际授予 `get-task-allow`；仅修改 entitlement 文本不能取得权限。
- 当前采用单应用运行模式，切换应用会重启进程，并保留各空间的文件数据。

多个空间只隔离文件目录。客体与 Retools 共享进程和权限，可以访问宿主文件与钥匙串，请只运行可信应用。推送、应用扩展及部分系统能力可能不兼容。

### 应用砸壳

1. 打开「应用 → 应用砸壳」，登录具有目标应用授权的商店账号。
2. 搜索应用，或从本机应用列表选择下载目标；也可导入自备的加密 IPA 和匹配许可。
3. 下载后，Retools 将目标安装包嵌入自建助手，使用所选开发身份签名，并经设备服务安装助手。
4. 助手在真机执行解密；Retools 取回结果后检查应用标识、二进制清单、加密状态和 SHA-256，再提供导出。

本机列表用于识别下载目标，实际输入仍来自商店下载。worse_query 不能因此直接取得任意已安装应用的受保护安装包。商店账号与开发签名账号分别配置，不使用 Mac 的 App Store 或 Xcode 登录状态代替商店会话。

首次使用需要联网准备并校验 Apple 组件，后续复用缓存。当前流程已在 iOS 27.0.1 真机完成端到端验证；其他系统和应用仍需验证。解密助手会临时占用额外空间，请先将成功结果导出并确认，再卸载助手或清理任务。

### 本机文件与进程操作

本机文件访问默认关闭，需要在设备工具中开启，并用自己的签名申请 `group.dev.retools.filetools.<TEAM>`。重新安装后，先检测真实 App Group 容器读写；系统拒绝授权的目录仍无法访问。

进程内存上限操作只作用于当前进程，进程重启后需要重新设置，并仍受设备整体内存限制。注销通过已配对的设备服务执行，会请求重启系统桌面，操作前会要求确认。

## 测试

`Tests/Fixtures` 内的证书和 IPA 均由脚本生成，测试密码为 `test-only`，不是个人签名资料，不能用于 iOS 安装。需要重新生成时执行：

```sh
python3 Scripts/make-test-fixtures.py
python3 Scripts/make-plugin-fixtures.py
python3 Scripts/make-host-group-fixtures.py
xcodegen generate
```

选择本机已安装的模拟器运行：

```sh
xcodebuild -project Retools.xcodeproj -scheme Retools \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGN_IDENTITY=- test
```

测试覆盖 IPA 解析、路径校验、原包保护、证书与签名、容器数据、续签决策、设备服务、砸壳任务和界面操作。需要真实加密安装包或网络运行时的可选测试默认跳过；模拟器测试不能替代真机解密与系统签名验证。

## 项目结构

```text
Host/                 宿主入口、签名配置与快捷指令
App/                  SwiftUI 页面、应用库、账号及设备功能
Native/               Objective-C / C / C++ 桥接
DecryptionCore/       解密任务执行与工作副本管理
DecryptionHelper/     独立解密助手
Runtime/              容器桥接、插件加载器与商店引擎
Rust/AppleSigning/    Apple ID 签名与设备配对桥接
ContainerControls/    悬浮切换侧栏
PairingWidget/        配对 Live Activity
Shared/               跨目标的数据格式与状态
Vendor/               固定版本源码、头文件和预编译依赖
Tests/, UITests/      单元测试、合成夹具和界面回归
Scripts/              构建、打包与测试数据生成
```

## 致谢

Retools 建立在以下开源项目的工作之上，感谢原作者及维护者：

| 项目 | 在 Retools 中的用途 |
| --- | --- |
| [LiveContainer](https://github.com/LiveContainer/LiveContainer) | 应用容器运行核心、应用修补与加载机制。 |
| [litehook](https://github.com/LiveContainer/litehook) | 容器运行时所需的底层 hook。 |
| [zsign](https://github.com/zhlynn/zsign) | Mach-O 与 IPA 签名。 |
| [isideload](https://github.com/nab138/isideload) | Apple ID 开发签名与认证基础。 |
| [SideStore / minimuxer](https://github.com/SideStore/minimuxer) | 设备连接与网关接口。 |
| [SideStore / idevice](https://github.com/SideStore/idevice)、[jkcoxson / idevice](https://github.com/jkcoxson/idevice) | iOS 设备服务、调试及配对底层接口。 |
| [worse_query](https://github.com/forcequitOS/worse_query) | 兼容系统上的本机文件访问。 |
| [IPATool](https://github.com/majd/ipatool) | 商店认证、应用下载与许可处理基础。 |
| [Unicorn TCI](https://github.com/1rhino2/unicorn-tci)、Unicorn / QEMU | 商店引擎使用的 TCI 解释器。 |
| [OpenSSL XCFramework](https://github.com/krzyzanowskim/OpenSSL)、[OpenSSL](https://github.com/openssl/openssl) | 签名与证书所需的密码库。 |
| [Lobe Icons](https://github.com/lobehub/lobe-icons) | AI 模型与服务商标识图标。 |

机制研究与流程设计还参考了 [fairplay-decrypt](https://github.com/EthanArbuckle/fairplay-decrypt) 和 [FairPlayed](https://github.com/morzelowski/FairPlayed)。这些参考与直接集成的源码依赖分别记录在[依赖说明](Docs/DEPENDENCIES.md)中。

## 许可证

Retools 自有代码采用 [AGPL-3.0](LICENSE)。各第三方组件保留原有版权声明与许可证，详见其源码目录和 [OpenSourceNotices.txt](Resources/OpenSourceNotices.txt)；应用设置中也提供开源许可入口。Retools 是独立项目，非上述项目的官方客户端。
