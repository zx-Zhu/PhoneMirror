import { AbilityConstant, ConfigurationConstant, UIAbility, Want, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { window } from '@kit.ArkUI';
import nativeBridge from 'libentry.so';

export default class EntryAbility extends UIAbility {
  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    nativeBridge.startServer(39876);
    backgroundTaskManager.on('continuousTaskCancel', (info) => {
      console.error(`HarmonyMac continuous task cancelled: reason=${info.reason}, id=${info.id}`);
    });
    this.startContinuousTask();
  }

  private async startContinuousTask(): Promise<void> {
    try {
      const notificationWant = await wantAgent.getWantAgent({
        wants: [{
          bundleName: 'com.zhuzhanxuan.phonemirror.companion',
          abilityName: 'EntryAbility'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 39876,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      await backgroundTaskManager.startBackgroundRunning(
        this.context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
        notificationWant
      );
      console.info('PhoneMirror continuous task started');
    } catch (error) {
      console.error(`PhoneMirror continuous task failed: ${JSON.stringify(error)}`);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index');
  }

  // 界面会话被系统回收不代表用户结束协同；后台任务和TCP服务继续运行。
  onDestroy(): void {}
}
