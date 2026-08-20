# Vedette CPU 保护（RootHide）

这是基于 [udevsharold/vedette](https://github.com/udevsharold/vedette) 的轻量修改版，目标环境为 iOS 15、Dopamine、RootHide、arm64e 和 Theos。项目保留 App/daemon 选择，只提供一种行为：目标 CPU 达到阈值一次后，在下一次采样时立即执行 `kill(pid, SIGKILL)`。

## 工作方式

- 仅监控用户在 Vedette 中明确启用的目标。
- 所有目标共用 `runningboardd` 内的一条串行队列和一个按需 timer。
- 固定采样周期约 250ms，不为每个 PID 创建线程。
- `ri_user_time`、`ri_system_time` 与 `mach_absolute_time` 均以 Mach ticks 计算，CPU 百分比直接使用同单位增量相除。
- 当前一次超限即终止；将 `VDT_IMMEDIATE_REQUIRED_VIOLATIONS` 改成 2 可扩展为连续两次超限。
- PID 退出或启动时间变化时立即移除。
- 执行 SIGKILL 前重新核对 PID 启动时间、executable 路径、bundle identifier 或 daemon name，避免 PID 重用误杀。
- 没有运行中的受监控目标时取消 timer，停止 CPU 采样。
- 不保存历史、不绘图、不建数据库、不扫描全系统 PID，采样路径没有高频日志。

App/daemon 启动时只发送一次 PID 通知。目标进程不读取沙盒外的 Vedette 偏好设置，由 `runningboardd` 读取配置并决定是否加入采样。

## 设置界面

设置页已精简和汉化，只包含：

- 总开关；
- 应用程序列表；
- 系统进程列表；
- 每个目标的启用开关；
- 每个目标的 CPU 阈值；
- 恢复默认设置。

应用列表由 Vedette 通过 `LSApplicationWorkspace` 按需读取，不依赖 AltList。赞助、联系、传统监控、CPU throttle 和持续时间设置均已移除。

## RootHide 注意事项

RootHide 默认不会向第三方 App 注入 tweak。监控 App Store App 前，需要先在 RootHide Bootstrap 的 App List 中允许目标 App 注入，然后彻底退出并重新打开 App，使新 PID 完成启动上报。

项目固定使用：

```make
THEOS_PACKAGE_SCHEME = roothide
ARCHS = arm64e
TARGET = iphone:clang:15.6:15.0
```

访问 bootstrap 内路径时使用 `jbroot(...)`，不硬编码 `/var/jb`。

## 构建

需要 macOS、Xcode 和 [RootHide Theos](https://github.com/roothide/theos)：

```sh
gmake clean
gmake package FINALPACKAGE=1 DEBUG=0 THEOS_PACKAGE_SCHEME=roothide ARCHS=arm64e
```

输出位于 `packages/*.deb`。GitHub Actions 会安装固定版本的 RootHide Theos 和经 SHA-256 校验的 patched iOS 15.6 SDK，并验证：

- deb 架构为 `iphoneos-arm64e`；
- tweak 与 PreferenceBundle 均为 arm64e；
- PreferenceBundle 不链接 AltList；
- 包依赖不包含 AltList；
- 源码不存在 Legacy/Throttle API 和全系统 PID 枚举；
- PreferenceLoader plist 正确；
- 包内没有 `/var/jb`。

## 设备验收

1. 安装 deb 后执行 RootHide Userspace Reboot，确保 `runningboardd` 载入新版 dylib。
2. 在 RootHide Bootstrap App List 中允许非关键测试 App 注入。
3. 在 Vedette 中启用该 App，并设置 CPU 阈值。
4. 彻底退出并重新打开目标 App。
5. 制造持续 CPU 负载，确认超过阈值后约一个采样周期内退出。
6. 重新启动 App 或测试 daemon，确认新 PID 自动恢复监控。
7. 关闭目标或总开关，确认不再终止。
8. 没有目标运行时观察 `runningboardd`，确认 Vedette 不保留 CPU sampling timer。

## 关键进程保护

`launchd`、`SpringBoard`、`backboardd`、`runningboardd`、`kernel_task`、`installd`、`jailbreakd` 以及 RootHide/Dopamine 核心辅助进程不能启用立即终止。设置 UI 与运行时均执行保护检查。

## Credits and license

- Original Vedette: udevs
- Daemon list code: opa334 / Choicy

原项目按 GPLv3 发布；Choicy 派生文件保留原有许可声明。参见 `LICENSE`。
