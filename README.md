# PhoneMirror

一款原生 macOS Android / HarmonyOS / iOS 投屏工具。Android 使用 scrcpy H.264；HarmonyOS 通过 HDC 临时运行投屏扩展；iPhone 和 iPad 使用 macOS 原生 CoreMediaIO / AVFoundation USB 采集，均无需在手机安装 App。

## 功能

- 同时发现 Android ADB 与 HarmonyOS / OpenHarmony HDC 设备
- 发现 USB 连接并已信任的 iPhone / iPad
- Android 使用 scrcpy 4.0 + VideoToolbox 硬件解码，最高 60 FPS
- HarmonyOS 通过临时 UiTest 扩展持续输出 H.264，启动失败时自动使用系统截图；两种平台均提供四档质量
- Android 与 HarmonyOS 支持鼠标点击、拖动、滚轮和键盘输入；iOS 为只读投屏
- Android 使用 scrcpy 实时触控；HarmonyOS 使用 UiTest RPC 实时发送 DOWN/MOVE/UP，连接失败时自动回退稳定的 click/swipe
- Android 与 HarmonyOS 支持返回、主页、多任务和电源等快捷操作
- 将 `.apk` 或 `.hap` 拖到对应设备的投屏画面，可覆盖安装并自动启动应用
- 两种平台均使用手机系统录屏，不依赖投屏画面
- iOS 使用 QuickTime USB 只读投屏，手机端无需安装 App；仅在用户主动开始投屏时请求一次 macOS 相机权限
- 截图生成 PNG 文件、录屏生成 MP4 文件，并直接写入 macOS 剪贴板
- 支持暂停画面、窗口置顶、断线自动恢复
- 镜像画布严格跟随手机比例，控制按钮纵向排列在画面右侧
- 全部数据在 USB 链路和本机处理

## 要求

- macOS 13 或更高版本
- Android SDK Platform Tools（Android 设备所需）
- DevEco Studio（提供 HarmonyOS 连接所需的 `hdc`）
- DevEco Testing macOS 26.0.0.400 或兼容版本（提供 HarmonyOS H.264 bridge 的 Python 运行时；未找到时自动回退截图流）
- libimobiledevice（iOS 发现、设备信息及截图回退；本机默认查找 Homebrew 路径）
- 手机开启开发者模式和 USB 调试，并完成调试授权

本机默认查找路径：

```text
/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
~/Library/Android/sdk/platform-tools/adb
```

也支持 `HDC_HOME`、`ANDROID_HOME` 或 `PATH` 中的对应工具。

## 构建与运行

按工程约定使用 `.run` 中的入口：

```bash
./.run/test.sh
./.run/build_and_open.sh
```

构建后的应用在 `dist/PhoneMirror.app`。它使用本地 ad-hoc 签名，可直接在当前 Mac 上运行。

HarmonyOS 持续 H.264 所需的临时扩展随 macOS App 一起打包，通过 HDC 部署到
`/data/local/tmp`，停止投屏时结束进程；手机端无需安装 HAP。

连接真机后可额外运行系统录屏集成测试：

```bash
PHONE_MIRROR_HARMONY_TEST_DEVICE=鸿蒙设备ID PHONE_MIRROR_ANDROID_TEST_DEVICE=安卓设备ID ./.run/test.sh
```

该测试会录制约 2 秒、验证 MP4 和文件剪贴板，然后删除手机媒体库中的测试视频。
未设置对应环境变量时，真机测试会自动跳过。

## 操作

| Mac 操作 | 手机操作 |
| --- | --- |
| 左键单击（Android / HarmonyOS） | 点击 |
| 左键拖动（Android / HarmonyOS） | 滑动 |
| 滚轮 / 触控板滚动（Android / HarmonyOS） | 页面滑动 |
| 右键 / Esc（Android / HarmonyOS） | 返回 |
| 中键（Android / HarmonyOS） | Home |
| 输入文字（Android / HarmonyOS） | 输入到当前焦点 |
| 拖入 `.apk`（Android） | 覆盖安装并启动应用 |
| 拖入 `.hap`（HarmonyOS） | 覆盖安装并启动应用 |
| 相机按钮 | 将当前画面保存为 PNG 文件并复制到剪贴板 |
| 录屏按钮 | 开始手机系统录屏；再次点击后将 MP4 文件复制到剪贴板 |

## 当前实现边界

HarmonyOS 使用 DevEco Testing 投屏扩展，经 HDC Unix socket 和本地 gRPC bridge 输出持续 H.264，再由 macOS VideoToolbox 解码。扩展启动失败时会回退到 `snapshot_display` 截图流。Android 通过内置的官方 scrcpy server 输出持续 H.264。

HarmonyOS 录屏调用系统 `com.huawei.hmos.screenrecorder`，停止后从媒体库导出；Android 录屏调用系统 `screenrecord` 并从 `Movies` 拉回。两者都不使用投屏帧合成。HarmonyOS 的音频来源沿用手机系统录屏设置；标准 Android `screenrecord` 仅保证画面。

截图和录屏文件缓存在 `~/Library/Caches/PhoneMirror/Clipboard/`，并作为文件对象写入剪贴板，可直接在 Finder、飞书或其他支持文件粘贴的应用中按 `Command-V`。受系统保护的支付、密码和 DRM 页面可能返回黑屏，这是手机系统的安全限制。

在 Mate 60 Pro（HarmonyOS 6.1）上的实测，均衡档单帧截图约 `0.33–0.35s`、USB 拉取约 `0.04–0.05s`，持续刷新约 `2.5 FPS`。
Android 使用 scrcpy 的连续 DOWN/MOVE/UP 控制协议；HarmonyOS 使用随应用内置的 UiTest 代理建立 HDC 端口转发，稳定连接后每次 MOVE 真机实测约 5ms。连接失败时自动回退 `uitest click/swipe`。

iOS 使用 QuickTime 同源的 `.muxed` AVFoundation 采集设备，只提供只读画面。手机端无需安装 App；只有用户主动开始 iOS 投屏时，macOS 才会请求一次相机权限，该权限实际用于读取 USB 屏幕源。PhoneMirror 不采集 iOS 音频，也不请求麦克风权限。

Android 安装包通过 `adb install -r` 覆盖安装，并从 APK manifest 读取 Launcher Activity 后启动。HarmonyOS 安装包通过 `hdc install -r` 覆盖安装，并从 HAP 的 `module.json` 读取 bundle、module 和 main ability 后启动。设备列表默认只展示在线设备。

## 隐私

PhoneMirror 不连接云服务，不上传画面，不采集遥测。应用只执行设备发现、屏幕截图和用户主动触发的输入命令。

第三方参考与许可证见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
