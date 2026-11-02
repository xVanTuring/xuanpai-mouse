# 玄派鼠标（macOS 配置工具）

玄派（Metapanda）**玄熊猫三模无线轻量化鼠标 P1 NearLink（星闪版）** 的非官方 macOS 配置工具。

官方只提供 Windows 驱动。本项目通过分析官方驱动与真机通信，还原了鼠标的 USB HID 配置协议，用 SwiftUI 做了一个 Mac 上可用的配置界面。

> 非官方项目，与玄派无关。设置会直接写入鼠标，请自行承担风险。

## 已支持

| 功能 | 读取 | 修改 |
|---|---|---|
| 连接方式（星闪接收器 / 有线） | ✅ | — |
| 序列号、电量 | ✅ | — |
| 回报率（125 / 500 / 1000 / 2000 / 4000 / 8000 Hz，无线最高 4000） | ✅ | ✅ |
| 提升距离 LOD（1 / 2 mm） | ✅ | ✅ |
| 按键消抖（2 / 4 / 8 ms） | ✅ | ✅ |
| DPI 档位（最多 7 档，200–26000） | ✅ | ✅ |

**菜单栏**：常驻菜单栏显示电量（默认），可选同时显示当前 DPI。点开菜单可以查看详情、切换显示项、打开主窗口。

应用默认不在 Dock 显示图标，启动后也不弹主窗口，只在菜单栏常驻；需要 Dock 图标时可在菜单里打开「在 Dock 显示图标」。电量和 DPI 档位由鼠标主动推送，变化后立即更新。

界面支持中文和英文，跟随系统语言。

### 真机验证情况

- 读取：全部已在真机验证。
- 写入：LOD、消抖已验证（写入后回读一致）；回报率、DPI 档位的写入格式来自官方驱动代码，尚未在真机上逐项验证。
- 尚未实现：按键映射、左右手互换、宏、DPI 指示灯开关。详见 [开发日志](LOG.md)。

## 构建与运行

需要 macOS 15 或更高版本、Xcode，以及 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
xcodegen generate
open XuanpaiMouse.xcodeproj
```

默认使用临时签名，可以直接构建。如果想用固定的开发证书（这样系统权限在重新编译后不会丢失）：

```bash
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
# 编辑文件，填入 `security find-identity -v -p codesigning` 查到的证书名
xcodegen generate
```

首次运行时，系统会要求授予 **输入监控** 权限（系统设置 → 隐私与安全性 → 输入监控）。鼠标的应答通过 HID 输入报文返回，没有这个权限就收不到。

运行单元测试：

```bash
xcodebuild -project XuanpaiMouse.xcodeproj -scheme XuanpaiMouse test
```

## 使用提示

- 星闪模式下，鼠标休眠时不会应答。如果界面提示"鼠标没有响应"，晃动一下鼠标再点「刷新」。
- 程序在两条命令之间会等待 1 秒。实测命令发得太密，无线鼠标会短暂失去响应，需要重新连接。
- 本项目**不涉及固件刷写**，也不要用本项目的代码去发送未经确认的命令。

## 目录

```
Sources/       应用源码（SwiftUI；协议编码解码、设备通信、界面）
Tests/         协议单元测试（用例来自真机抓取的应答）
docs/          协议文档
tools/mphid/   命令行调试工具（Swift 单文件），用于发送报文并打印应答
Config/        签名配置
LOG.md         开发日志
```

## 协议文档

见 [docs/PROTOCOL.md](docs/PROTOCOL.md)：通道、命令格式、应答格式，以及哪些内容已在真机验证。

## 调试工具

```bash
swiftc -O tools/mphid/main.swift -o mphid
./mphid list                 # 列出设备
./mphid xfer 45 ff           # 发送读取 DPI 的报文，并打印应答
```

`xfer` 会自动补上报告号 `0xA0` 并填充到 64 字节。读取类命令是安全的；写入类命令会改变鼠标设置，使用前请先阅读协议文档。

## 许可

暂未指定许可证。
