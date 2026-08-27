export interface NativeStatus {
  connected: boolean;
  capturing: boolean;
  ip: string;
}

export const startServer: (port: number) => number;
export const stopServer: () => void;
export const startCapture: () => number;
export const stopCapture: () => void;
export const getStatus: () => NativeStatus;
export const pollControl: () => string;
export const listInbox: () => string[];
export const sendFile: (fd: number, name: string) => void;
