# Vedette Immediate for RootHide

这是基于 [udevsharold/vedette](https://github.com/udevsharold/vedette) 的小范围修改版，目标是 iOS 15、Dopamine、RootHide、arm64e。它保留原有 App/daemon 选择、legacy monitor 和 throttle，同时新增轻量的立即终止模式。

## 立即终止模式

- 只采样用户明确启用、策略为 `Immediate` 且当前正在运行的目标。
- 所有目标共用 `runningboardd` 内的一条串行监控队列和一个按需 timer，不为每个 PID 创建线程。
- 采样周期是内部常量，约 250ms；一次采样达到或超过阈值即执行 `kill(pid, SIGKILL)`。
- 当前连续超限次数常量为 1；将 `VDT_IMMEDIATE_REQUIRED_VIOLATIONS` 改为 2 即可扩展为连续两次超限。
- 目标退出或身份校验失败后移除 PID；没有立即模式目标时销毁 timer，完全停止 CPU 采样。
- 不记录 CPU 历史、不绘图、不建数据库，采样路径中没有高频日志。

执行 SIGKILL 前会重新核对进程启动时间、executable 路径以及 bundle identifier 或 daemon 名称，以防 PID 失效和 PID 重用。`launchd`、`SpringBoard`、`backboardd`、`runningboardd`、`kernel_task`、`installd`、`jailbreakd` 以及 RootHide/Dopamine 核心辅助进程被硬保护，不能使用立即终止。

## RootHide

项目固定使用：

```make
THEOS_PACKAGE_SCHEME = roothide
ARCHS = arm64e
TARGET = iphone:clang:latest:15.0
```

运行时访问 bootstrap 内的 PreferenceBundle、LaunchDaemons 和工具目录均使用 RootHide 的 `jbroot(...)` API，没有硬编码 `/var/jb`。包架构由 RootHide Theos 生成为 `iphoneos-arm64e`。

RootHide 默认不会向第三方 App 注入 tweak。若要监控 App Store App，需要先在 RootHide Bootstrap 的 App List 中为该 App 启用 tweak injection；之后 App 每次以新 PID 启动都会重新上报并自动恢复监控。系统 daemon 同样在每次重新启动后上报新 PID。

## 构建

需要 macOS、Xcode、[RootHide Theos](https://github.com/roothide/theos) 以及 RootHide 版 AltList framework：

```sh
gmake clean
gmake package FINALPACKAGE=1 DEBUG=0 THEOS_PACKAGE_SCHEME=roothide ARCHS=arm64e
```

输出位于 `packages/*.deb`。GitHub Actions 工作流 `.github/workflows/build-roothide.yml` 会安装固定版本的 RootHide Theos 和经 SHA-256 校验的 RootHide AltList，构建后验证：

- deb 架构是 `iphoneos-arm64e`；
- tweak dylib 与 PreferenceBundle executable 都包含 `arm64e`；
- PreferenceLoader plist 指向 `VedettePrefs`；
- 包内没有 `/var/jb`；
- CPU 监控实现没有全系统 PID 枚举。

构建成功后可从 Actions run 的 `vedette-roothide-arm64e` artifact 下载可安装 deb。

## 设备验证建议

编译检查不能代替真机行为测试。建议在可恢复的测试设备上依次验证：

1. 设置页能显示，并能分别选择 App 和 daemon。
2. 对非关键测试进程启用 `Immediate`，设置 80%、90% 或 100% 阈值。
3. 制造持续 CPU 负载，确认达到阈值后约一个已建立基线的采样周期内被 SIGKILL。
4. 让 App 和 daemon 重新启动，确认新 PID 自动恢复监控。
5. 关闭单个目标或总开关，确认立即采样停止。
6. 没有目标运行时观察 `runningboardd`，确认本 tweak 不保留 CPU sampling timer。
7. 尝试给受保护进程选择 Immediate，确认 UI 拒绝；运行时保护仍是最终防线。

## Credits and license

- Original Vedette: udevs
- Daemon list code: opa334 / Choicy
- App selection: AltList

原项目代码按 GPLv3 发布；Choicy 派生文件保留其原有许可声明。参见 `LICENSE`。
