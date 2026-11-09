# 依赖、来源与本地适配

本文件记录 Retools 0.1.0 (51) 使用的固定上游版本及本地修改，更新于 2026-11-10。使用和构建说明见 [README](../README.md)。各组件的完整许可保留在对应目录，并汇总于 [OpenSourceNotices.txt](../Resources/OpenSourceNotices.txt)。

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
| IPATool | [majd/ipatool](https://github.com/majd/ipatool)，`536d7bacc1c579d4420d0f4d2045368dcbf68732` | MIT；上游仿真 profile 随源码保留 |
| Unicorn TCI | [1rhino2/unicorn-tci](https://github.com/1rhino2/unicorn-tci)，`e3f075a62742913bb734a55a474aec65c9e5745e` | GPL-2.0 及其 QEMU / GLib 等组件许可 |
| Lobe Icons | [lobehub/lobe-icons](https://github.com/lobehub/lobe-icons)，`ea434b96e75813517b377825e01c0df61dee8836` | MIT |

Rust 和 Go 的传递依赖版本分别由 `Rust/AppleSigning/Cargo.lock`、`Runtime/StoreEngine/go.mod` / `go.sum`、`Vendor/IPATool/go.mod` / `go.sum` 固定。

Lobe Icons 的八个服务商标识用于 AI 页面；SVG 尺寸、模板颜色及圆弧表示按 Xcode 资源编译要求规范化，MIT 许可全文随应用保留。

## LiveContainer 与 litehook

集成运行核心及 litehook。Retools 自行提供工作台、凭据管理、签名、插件加载器和侧栏 UI，当前未集成上游 LiveProcess 多任务扩展或 TweakLoader。

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

`Vendor/WorseQuery` 保留上游核心源码、README 和完整许可，核心未修改。只编译 `worse_query.m` / `.h`，未接入上游演示 UI 或 pathleak 扫描。Retools 的 `RTLocalFileAccess.mm` 提供系统版本、工作台、App Group、路径检查和权限释放处理；文件浏览为只读。

OpenSSL 仅保留上游 iOS arm64 和模拟器切片，并相应调整 XCFramework 的平台清单。ZIPFoundation 用于归档读写。Debian 插件解包链接系统 libarchive，仓库只包含带许可的公开头文件。

插件导入、清单校验与 `Runtime/PluginLoader` 均为 Retools 自有实现；`.deb` 的安装脚本不会执行。

## 商店引擎与解密助手

`Runtime/StoreEngine` 显式接收 Retools 的商店会话，将状态交还设备钥匙串；嵌入式构建排除桌面 keyring 提供器。商店账号与开发签名账号独立。

`Scripts/build-store-engine.py` 从桥接源码、IPATool 和 Unicorn TCI 构建静态 XCFramework，只启用 TCI 解释器。Unicorn / QEMU 对应源码及许可随 `Vendor/UnicornTCI` 保留。

IPATool 本地适配包括操作取消、分阶段进度、已校验组件的复用、FairPlayIOKit ZIP 范围读取缓冲、商店地区解析、认证状态刷新以及下载许可合并。其额外 Apple 系统组件运行时从 Apple 下载并核对固定摘要。

`DecryptionHelper`、`DecryptionCore`、`Shared/FairPlayFormat.swift` 和 `Native/RTFairPlayNative.c` 为 Retools 的助手、任务格式与系统调用封装。目标二进制在助手签名阶段保持原始哈希，解密只写工作副本，完成后校验清单与输出。助手模板由仓库源码构建，未使用参考 IPA 的助手二进制。

## 机制研究与交互参考

以下项目用于机制或流程研究，与上表中的直接源码依赖分别列示：

- [EthanArbuckle/fairplay-decrypt](https://github.com/EthanArbuckle/fairplay-decrypt)：FairPlay、许可与加密 IPA 的机制研究；参考提交 `d81d98b13656c9dbb340f04dd0838137278f44a5`。
- [morzelowski/FairPlayed](https://github.com/morzelowski/FairPlayed)：已安装助手、只读映射与系统解密的机制说明；参考提交 `bad7df138839b5e0ac8b9f20cc4689140b8436fb`，未复制其实现源码。

用户提供的参考 IPA 仅用于静态分析；这些安装包及其中的个人签名资料不随源码仓库提交。
