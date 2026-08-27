import nativeBridge, { NativeStatus } from 'libentry.so';
import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import common from '@ohos.app.ability.common';
import accessibility from '@ohos.accessibility';

@Entry
@Component
struct Index {
  @State status: NativeStatus = { connected: false, capturing: false, ip: '0.0.0.0' };
  @State message: string = '等待Mac连接';
  @State inbox: string[] = [];
  @State accessibilityStatus: string = '正在检测键鼠控制服务…';
  private timerId: number = -1;

  aboutToAppear(): void {
    nativeBridge.startServer(39876);
    const captureResult = nativeBridge.startCapture();
    this.message = captureResult === 0
      ? '请允许系统录屏，然后回到任意应用'
      : `自动启动失败：${captureResult}，可点击下方按钮重试`;
    this.refreshAccessibilityStatus();
    this.refreshStatus();
    this.timerId = setInterval(() => this.refreshStatus(), 1000);
  }

  private refreshAccessibilityStatus(): void {
    try {
      const installed = accessibility.getAccessibilityExtensionListSync('all', 'install');
      const ownService = installed.find(item => item.bundleName === 'com.zhuzhanxuan.phonemirror.companion');
      this.accessibilityStatus = ownService
        ? `系统已识别：${ownService.label || 'PhoneMirror远程控制'}`
        : '系统尚未识别键鼠控制服务';
    } catch (error) {
      this.accessibilityStatus = `服务检测失败：${(error as Error).message}`;
    }
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
    }
  }

  private refreshStatus(): void {
    this.status = nativeBridge.getStatus();
    this.inbox = nativeBridge.listInbox();
    this.message = this.status.connected ? 'Mac已连接' : '等待Mac连接';
  }

  private async chooseAndSendFile(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const documentPicker = new picker.DocumentViewPicker(context);
      const uris = await documentPicker.select({
        maxSelectNumber: 1,
        selectMode: picker.DocumentSelectMode.FILE
      });
      if (uris.length === 0) {
        return;
      }
      const uri = uris[0];
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const parts = uri.split('/');
      const rawName = parts[parts.length - 1] || 'phone-file';
      let name = rawName;
      try {
        name = decodeURIComponent(rawName);
      } catch (_) {
      }
      nativeBridge.sendFile(file.fd, name);
      fs.closeSync(file);
      this.message = `正在发送：${name}`;
    } catch (error) {
      this.message = `选择文件失败：${(error as Error).message}`;
    }
  }

  build() {
    Scroll() {
      Column({ space: 18 }) {
        Text('PhoneMirror Companion')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)

        Text('持续 H.264 屏幕镜像服务')
          .fontSize(14)
          .fontColor('#667085')

        Column({ space: 8 }) {
          Text(this.message)
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
          Text(`${this.status.ip}:39876`)
            .fontSize(22)
            .fontFamily('monospace')
          Text('在Mac客户端中输入上面的地址')
            .fontSize(13)
            .fontColor('#667085')
        }
        .width('100%')
        .padding(20)
        .backgroundColor('#EEF4FF')
        .borderRadius(18)

        Button(this.status.capturing ? '停止屏幕协同' : '开始屏幕协同')
          .width('100%')
          .height(52)
          .fontSize(17)
          .onClick(() => {
            if (this.status.capturing) {
              nativeBridge.stopCapture();
              this.message = '屏幕协同已停止';
            } else {
              const result = nativeBridge.startCapture();
              this.message = result === 0 ? '请允许系统录屏，然后回到任意应用' : `启动失败：${result}`;
            }
            this.refreshStatus();
          })

        Button('选择文件发送到Mac')
          .width('100%')
          .height(48)
          .buttonStyle(ButtonStyleMode.NORMAL)
          .onClick(() => this.chooseAndSendFile())

        Column({ space: 8 }) {
          Text('开启键鼠控制')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .width('100%')
          Text('HarmonyOS 6：设置 → 关怀和无障碍，找到“Harmony Mac远程控制”后开启')
            .fontSize(14)
            .fontColor('#475467')
            .width('100%')
          Text(this.accessibilityStatus)
            .fontSize(13)
            .fontColor('#0A59F7')
            .width('100%')
          Text('首次只需开启一次。未开启时仍可观看屏幕和互传文件。')
            .fontSize(12)
            .fontColor('#98A2B3')
            .width('100%')
        }
        .padding(18)
        .backgroundColor('#F9FAFB')
        .borderRadius(16)

        Column({ space: 8 }) {
          Text('Mac传入的文件')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .width('100%')
          if (this.inbox.length === 0) {
            Text('尚无文件。可将Finder文件拖进Mac端手机窗口。')
              .fontSize(13)
              .fontColor('#98A2B3')
              .width('100%')
          } else {
            ForEach(this.inbox, (name: string) => {
              Text(name)
                .fontSize(14)
                .width('100%')
                .padding(10)
                .backgroundColor(Color.White)
                .borderRadius(8)
            }, (name: string) => name)
          }
        }
        .width('100%')
        .padding(18)
        .backgroundColor('#F2F4F7')
        .borderRadius(16)
      }
      .width('100%')
      .padding(24)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.White)
  }
}
