# HarmonyOS 手机端

手机端使用 ArkTS + HarmonyOS NDK：

- `OH_AVScreenCapture` 获取屏幕 Surface。
- `OH_VideoEncoder` 硬件编码 H.264。
- C++ TCP 服务发送视频并收发文件、控制消息。
- `AccessibilityExtensionAbility` 执行远程手势和文字输入。

构建：

```bash
../.run/build_companion.sh
```

生成位置：

```text
entry/build/default/outputs/default/entry-default-unsigned.hap
```

真机安装需要在 DevEco Studio 的 `File → Project Structure → Signing Configs` 中，
为 `com.zhuzhanxuan.phonemirror.companion` 开启 HarmonyOS 自动调试签名。签名构建后运行：

```bash
../.run/install_companion.sh
```
