# Changelog

本文件格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added
- 基于 Azahar 2126.2 的 iOS 前端：SwiftUI 界面、Vulkan（MoltenVK）渲染、虚拟手柄、实体手柄、陀螺仪。
- iOS 17–26 的 JIT（含 iOS 26 TXM 设备上的 StikDebug 通用脚本协议），无 JIT 时退回解释器。
- 联机：Azahar 房间协议、局域网 Bonjour 发现、自建大厅。
- 游戏导入：「文件」App / Finder / iTunes 放入文件后自动扫描；CIA 自动安装（本体、更新、DLC），加密内容给出明确提示。
- 即时存档 10 个位置、快进、截图。

### Fixed
- dynarmic：运行中途清空代码缓存后，返回地址缓存（RSB）未重置，导致跳转到地址 0 崩溃。
- 快进被 FIFO 呈现卡在 100%。
- 读档泄漏整个旧游戏进程，存档泄漏纹理缓存，存档时内存尖峰约 1.4 GB（曾导致 iOS 因 3 GB 内存上限强制关闭 App）。
- 截图在 MoltenVK 上每张残留约 2.8 MB 显存。
- 即时存档里保存了绝对路径：App 重装或更新后，数据目录路径改变，读旧档后游戏自己的存档失败并报「模拟器出错」。
- 被系统界面打断后静默暂停（现在会弹出暂停菜单）。
- 暂停菜单显示时，如果游戏被其他途径恢复运行，菜单不会关闭，出现「菜单开着、游戏在跑」的状态（现在恢复运行时自动关闭菜单）。
