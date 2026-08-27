import AccessibilityExtensionAbility from '@ohos.application.AccessibilityExtensionAbility';
import { GesturePath } from '@ohos.accessibility.GesturePath';
import { GesturePoint } from '@ohos.accessibility.GesturePoint';
import display from '@ohos.display';
import pasteboard from '@ohos.pasteboard';
import nativeBridge from 'libentry.so';

interface PointerCommand {
  action: string;
  x: number;
  y: number;
  x2?: number;
  y2?: number;
  duration?: number;
}

export default class RemoteControlAccessibilityAbility extends AccessibilityExtensionAbility {
  private timerId: number = -1;

  onConnect(): void {
    this.timerId = setInterval(() => this.poll(), 16);
  }

  onDisconnect(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  onAccessibilityEvent(): void {
  }

  private poll(): void {
    const command = nativeBridge.pollControl();
    if (command.length < 2) {
      return;
    }
    if (command.startsWith('P:')) {
      this.handlePointer(command.substring(2));
    } else if (command.startsWith('T:')) {
      this.handleText(command.substring(2));
    }
  }

  private handlePointer(json: string): void {
    try {
      const command = JSON.parse(json) as PointerCommand;
      const screen = display.getDefaultDisplaySync();
      const startX = Math.round(command.x * screen.width);
      const startY = Math.round(command.y * screen.height);
      const endX = Math.round((command.x2 ?? command.x) * screen.width);
      const endY = Math.round((command.y2 ?? command.y) * screen.height);
      const duration = command.duration ?? (command.action === 'tap' ? 60 : 280);
      const path = new GesturePath(duration);
      path.points = [new GesturePoint(startX, startY)];
      if (command.action !== 'tap') {
        path.points.push(new GesturePoint(endX, endY));
      }
      this.context.injectGestureSync(path);
    } catch (_) {
    }
  }

  private async handleText(text: string): Promise<void> {
    try {
      const focused = await this.context.getFocusElement(false);
      if (text === '\b') {
        await focused.performAction('delete');
        return;
      }
      const systemPasteboard = pasteboard.getSystemPasteboard();
      await systemPasteboard.setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
      await focused.performAction('paste');
    } catch (_) {
    }
  }
}
