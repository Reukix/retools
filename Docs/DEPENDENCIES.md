# 依赖、来源与本地适配

本文件记录 Retools 0.1.0 (58) 使用的固定上游版本及本地修改，更新于 2026-11-11。使用和构建说明见 [README](../README.md)。各组件的完整许可保留在对应目录，并汇总于 [OpenSourceNotices.txt](../Resources/OpenSourceNotices.txt)。

## 直接依赖

| 组件 | 上游与固定版本 | 许可 |
| --- | --- | --- |
| LiveContainer runtime | [LiveContainer/LiveContainer](https://github.com/LiveContainer/LiveContainer)，`9108ae624ea001f7d7696d48407f890b48fa2653` | AGPL-3.0 |
| litehook | [LiveContainer/litehook](https://github.com/LiveContainer/litehook)，`a7e9f599d7f0b3d77008ad62bf10cb10dab6eca9` | MIT |
| zsign | [zhlynn/zsign](https://github.com/zhlynn/zsign)，`9299685bab7ef99827e06e5dfda93af747386590` | MIT |
| OpenSSL XCFramework | [krzyzanowskim/OpenSSL](https://github.com/krzyzanowskim/OpenSSL)，`0a6149bff4fb00921ce0ec1811f726b166638095` | Apache-2.0 |
| ZIPFoundation | [weichsel/ZIPFoundation](https://github.com/weichsel/ZIPFoundation)，`0.9.20` | MIT |
| isideload | [nab138/isideload](https://github.com/nab138/isideload)，`326e56229d0727cb6e7b34c8cf03e37e2cd3e17d` | MIT |
| Minimuxer Common / IdeviceGateway | [SideStore/minimuxer](https://github.com/SideStore/minimuxer)，`12be70dc2627307a16bfd2dc7a009080d5bec909` | AGPL-3.0 |
| IDevice XCFramework | [SideStore/idevice](https://github.com/SideStore/idevice)，`v0.1.68-ss-3e55c84`，提交 `3e55c8486b2057e40c1f74aaaa1155c82341cf76` | MIT |
| Rust idevice | [jkcoxson/idevice](https://github.com/jkcoxson/idevice)，Cargo.lock 固定的 `0.1.68` | MIT |
| libarchive 公共头文件 | [libarchive/libarchive](https://github.com/libarchive/libarchive)，`3.8.6`；实现使用 iOS 系统库 | BSD-2-Clause |
| worse_query | [forcequitOS/worse_query](https://github.com/forcequitOS/worse_query)，`d1540e20cd82b974d891e0551ced6d6aeb570ac2` | GPL-3.0-or-later |
| WQFiles 容器枚举适配 | [kolbicz/WQFiles](https://github.com/kolbicz/WQFiles)，`78a41d009ba684aa9f6ca44b7ecfc4f06f11b9bd` | GPL-3.0-or-later |
| iPadn store browser | [mengangs/ipadn](https://github.com/mengangs/ipadn)，`e91583bd300a0cc6f7b0c16c87e21819c35e7d01`（1.9.0 / 25） | GPL-2.0-or-later；运行组件来源见随附 PROVENANCE.json |
| IPATool | [majd/ipatool](https://github.com/majd/ipatool)，`536d7bacc1c579d4420d0f4d2045368dcbf68732` | MIT；上游仿真 profile 随源码保留 |
| Unicorn TCI | [1rhino2/unicorn-tci](https://github.com/1rhino2/unicorn-tci)，`e3f075a62742913bb734a55a474aec65c9e5745e` | GPL-2.0 及其 QEMU / GLib 等组件许可 |
| Lobe Icons | [lobehub/lobe-icons](https://github.com/lobehub/lobe-icons)，`ea434b96e75813517b377825e01c0df61dee8836` | MIT |

Rust 和 Go 的传递依赖版本分别由 `Rust/AppleSigning/Cargo.lock`、`Runtime/StoreEngine/go.mod` / `go.sum`、`Vendor/IPATool/go.mod` / `go.sum` 固定。

Lobe Icons 的八个服务商标识用于 AI 页面；SVG 尺寸、模板颜色及圆弧表示按 Xcode 资源编译要求规范化，MIT 许可全文随应用保留。

## LiveContainer 与 litehook

集成运行核心、litehook、上游 TweakLoader 的单进程插件与 UIKit / 文件选择器 / 通知兼容处理。Retools 自行提供工作台、凭据管理、签名和侧栏 UI，未集成上游 LiveProcess 多任务扩展。

TweakLoader 与经典显示模式探测适配自同一固定提交 `9108ae624ea001f7d7696d48407f890b48fa2653`；Retools 将客体应用切换交回工作台，继续执行签名、JIT 和应用锁检查。所选插件沿用 Retools 的逐库顺序、弱链接及资源目录，由 TweakLoader 在正常注入模式加载；延后模式仅运行兼容修复。支持逐应用 SDK、Dyld 隐藏、系统服务标识、语言、方向与经典显示设置，以及逐数据空间的 App Group 和 IDFV 设置。

`Vendor/LiveContainer/Resources/Frameworks/CydiaSubstrate.framework` 随上游提供 ElleKit 的 Substrate 兼容运行库，仅嵌入真机版本，许可为 BSD-3-Clause，全文见 `Resources/Licenses/ElleKit.txt`。不集成外部 LiveContainer 实例共享、多任务或它们所需的扩展。

本地适配集中于 `Vendor/LiveContainer/LiveContainer`：

- 入口改由 `Host/main.c` 选择客体或 SwiftUI 工作台，模拟器直接进入工作台。
- 调整核心头文件及 UI 依赖；为空团队、空 entitlement 和无 App Group 的私有目录模式提供保护。
- 钥匙串组前缀使用 Retools；证书密码由宿主钥匙串读取，不作为明文配置保存。
- 免 JIT 与 JIT 启动分别执行签名加载检测和实际调试状态检查。
- 在客体启动期间接入 Retools 自有的插件桥接及 `ContainerControls`，切换请求重新经过宿主检查。

容器的数据空间和钥匙串 hook 不构成新的系统安全边界。客体与宿主运行于同一进程。

## 签名、Apple ID 与设备服务

`Vendor/ZSign` 为动态库补齐空 XML / DER entitlement 及 CodeDirectory 特殊槽哈希。其他签名编排和校验由 Retools 实现。

`Rust/AppleSigning` 是 Retools 的 JSON / C 桥接，调用 isideload 和固定版本的 idevice。isideload 的本地修改包括 HTTP 状态检查、超时和 Anisette provisioning socket 的关闭处理。桥接传入和返回显式会话状态；开发者账号在 Retools 内配置。

Minimuxer 只采用 Common 和 IdeviceGateway，调整了同模块访问级别和原来的跨模块导入。未采用其 VPN / EMProxy 主模块。

`Vendor/IDevice.xcframework` 的两个静态库由上述 SideStore 标签的 `ffi` crate 编译，保留对应公开头文件。除上游基础功能外，启用了 crashreportcopymobile、diagnostics_relay、syslog_relay、location_simulation、notification_proxy、device_info、screenshotr、sysmontap、condition_inducer、energy_monitor 和 network_monitor；真机沿用上游 obfuscate 配置。

设备配对的 Swift 协调器、C 回调、取消、广播校验和保存流程由 Retools 实现。自身调试的协议协商参考 [LLDB remote protocol](https://lldb.llvm.org/resources/lldbgdbremote.html)，通信使用固定版本 idevice 的公开 API。

## 文件、归档与插件

`Vendor/WorseQuery` 保留上游核心源码、README 和完整许可，核心未修改。只编译 `worse_query.m` / `.h`，未接入上游演示 UI 或 pathleak 扫描。Retools 的 `RTLocalFileAccess.mm` 提供系统版本、工作台、App Group、路径检查和权限释放处理；本机文件提供受 Unix 文件权限限制的读写操作。

用户提供的 WQFiles 0.7 IPA 用于核对分类和访问方式，并核对了上表固定版本的源码。`Native/RTLocalFileCatalog.mm` 改编本机容器查询及 `fsgetpath` 枚举方式，保留 GPL-3.0-or-later 标识；对应许可正文与 worse_query 一并见开源许可。先读取本机目录元数据，额外扫描由用户触发，按短批次返回进度，可停止或离开页面暂停。不复用 WQFiles 的写入、清理、长期持有访问权限或 LaunchServices 数据库解析实现；目录列表可能不完整，缓存可能过期。应用数据、扩展、App Group、内部守护进程和 iOS 27 系统容器沿用同一个按操作获取并释放权限的服务。

`LocalFileMutation.swift` 和 `LocalFileEditor.swift` 实现 Retools 的本机写入与编辑：描述符逐级打开并拒绝符号链接，保存前核对文件版本，原地写入保留 inode、所有者与模式；覆盖和删除前流式备份，写入失败时只在内容仍吻合本次写入的情况下尝试恢复原描述符。导入新文件和重命名使用排他提交，目录只允许删除空目录，文件备份存储受保护。编辑时不持有越权目录句柄，读写完成后释放权限；直接编辑上限 2 MB，导入与导出按块处理。文件锁与版本校验不能保证不遵守锁的外部进程不会在操作间隙改动文件。

OpenSSL 仅保留上游 iOS arm64 和模拟器切片，并相应调整 XCFramework 的平台清单。ZIPFoundation 用于归档读写；工作台与商店模块共用一个动态框架，独立解密助手继续自行编译相同的归档源码。Debian 插件解包链接系统 libarchive，仓库只包含带许可的公开头文件。

插件导入、清单校验与 `Runtime/PluginLoader` 均为 Retools 自有实现；`.deb` 的安装脚本不会执行。

## 商店引擎与解密助手

`Vendor/IPadn` 保留 iPadn 的商店搜索、历史版本、版本 ID 下载、多账号、已购、下载队列、关注与比价、安装包浏览及安装服务。新增 `IPadnKit` 模块；资料、账号钥匙串、偏好及后台会话均与原工作区隔离，资源从模块 bundle 读取。独立 iPadn 的图标切换及自身更新入口不出现在 Retools 中。后台会话交回 Retools 的 UIApplicationDelegate，商店更新检查使用独立 BGTask 标识。 界面适配沿用 Retools 的暖色背景、语义文字颜色和主操作渐变，采用原生 SwiftUI NavigationStack、List / Section、Button、swipeActions 和 fileImporter。自定义 UIKit 侧滑识别器及私有 SwiftUI 行布局已移除，商店与设备应用的历史版本入口直接参与 Retools 的 NavigationStack，采用相同的系统推进、返回和侧滑手势；四个分区改为顶部原生切换与概览卡片，外观跟随 Retools；正常名称、说明及普通操作不继承品牌橙色。

下载的原始 IPA 可导入应用库、准备解密助手，或进入「安装版本 / 降级」。设备安装通过现有 IdeviceGateway 分块上传原始 IPA，保持 iTunesMetadata 与 SINF，已安装应用使用系统 Upgrade 请求；覆盖失败不会自动卸载。用户另行确认卸载重装时，可访问数据必须先完成备份；无法备份的应用明确说明数据会删除。备份保留在现有备份列表，手动恢复，旧版数据兼容性及系统安装限制仍适用。不会在这个流程中替换 Retools 自身。

iPadn 的 Mac PKG Go 包装器改编于同一提交，合并进 `Runtime/StoreEngine`，复用现有固定 IPATool 和无 JIT Unicorn；不引入第二份 Go runtime。SAP WebAssembly/JS 资源按上游清单校验，出处及原许可注释保留；完整来源说明位于 `Vendor/IPadn/THIRD_PARTY_NOTICES.md` 和 `Resources/SAPRuntime/PROVENANCE.json`。未引入上游重复的 Rust 配对安装服务，设备配对继续使用 Retools 的现有服务。


`Runtime/StoreEngine` 显式接收 Retools 的商店会话，将状态交还设备钥匙串；嵌入式构建排除桌面 keyring 提供器。商店账号与开发签名账号独立。

`Scripts/build-store-engine.py` 从桥接源码、IPATool 和 Unicorn TCI 构建静态 XCFramework，只启用 TCI 解释器。Unicorn / QEMU 对应源码及许可随 `Vendor/UnicornTCI` 保留。

IPATool 本地适配包括操作取消、分阶段进度、已校验组件的复用、FairPlayIOKit ZIP 范围读取缓冲、商店地区解析、认证状态刷新以及下载许可合并。其额外 Apple 系统组件运行时从 Apple 下载并核对固定摘要。

`DecryptionHelper`、`DecryptionCore`、`Shared/FairPlayFormat.swift` 和 `Native/RTFairPlayNative.c` 为 Retools 的助手、任务格式与系统调用封装。目标二进制在助手签名阶段保持原始哈希，解密只写工作副本，完成后校验清单与输出。助手模板由仓库源码构建，未使用参考 IPA 的助手二进制。

## 机制研究与交互参考

以下项目用于机制或流程研究，与上表中的直接源码依赖分别列示：

- [EthanArbuckle/fairplay-decrypt](https://github.com/EthanArbuckle/fairplay-decrypt)：FairPlay、许可与加密 IPA 的机制研究；参考提交 `d81d98b13656c9dbb340f04dd0838137278f44a5`。
- [morzelowski/FairPlayed](https://github.com/morzelowski/FairPlayed)：已安装助手、只读映射与系统解密的机制说明；参考提交 `bad7df138839b5e0ac8b9f20cc4689140b8436fb`，未复制其实现源码。
- 用户提供的 `FairDecrypt.scripting`（0.1.0）：参考应用概览、输入选择、未签名助手导出和证书安装两种输出方式。未复制脚本源码或助手二进制，继续使用 Retools 的助手、签名、许可与结果校验实现。

用户提供的参考 IPA 仅用于静态分析；这些安装包及其中的个人签名资料不随源码仓库提交。

商店的安装和解密交接沿用工作台：从商店面板发起交接时先结束系统面板，再展示安装页或进入解密工具。导入完成后仍保留原始下载文件。
