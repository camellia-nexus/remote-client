export type SessionMode =
  | 'remote'
  | 'file-transfer'
  | 'view-camera'
  | 'terminal'
  | 'port-forward'
  | 'rdp';

export type ConnectionState =
  | 'idle'
  | 'connecting'
  | 'connected'
  | 'auth'
  | 'streaming'
  | 'closed'
  | 'error';

export type ConnectRequest = {
  id: string;
  password?: string;
  sessionId?: string;
  mode: SessionMode;
  forceRelay?: boolean;
};

export interface SessionSecurityPolicy {
  viewOnly: boolean;
  disableKeyboard: boolean;
  disableClipboard: boolean;
  disableAudio: boolean;
  enableFileTransfer: boolean;
  lockAfterSessionEnd: boolean;
  showRemoteCursor: boolean;
  showMyCursor: boolean;
  followRemoteCursor: boolean;
  followRemoteWindow: boolean;
}

export type SessionContext = {
  rendezvousServer: string;
  relayServer: string;
  defaultIdPort: number;
  apiServer: string;
  key: string;
  token: string;
  myId: string;
  myName: string;
  version: string;
  buildDate: string;
  platform: string;
  imageQuality: string;
  customImageQuality: number;
  customFps: number;
  codecPreference: string;
  preferI444: boolean;
  policy: SessionSecurityPolicy;
};
