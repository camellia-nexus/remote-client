import type { SessionSecurityPolicy } from './types.ts';

export class SessionPolicyGuard {
  private policy: SessionSecurityPolicy;

  constructor(policy: SessionSecurityPolicy) {
    this.policy = policy;
  }

  getPolicy(): Readonly<SessionSecurityPolicy> {
    return this.policy;
  }

  updatePolicy(updates: Partial<SessionSecurityPolicy>): void {
    Object.assign(this.policy, updates);
  }

  isViewOnly(): boolean {
    return this.policy.viewOnly;
  }

  canSendKeyboard(): boolean {
    return !this.policy.viewOnly && !this.policy.disableKeyboard;
  }

  canSendMouse(): boolean {
    return !this.policy.viewOnly;
  }

  canSendControl(): boolean {
    return !this.policy.viewOnly;
  }

  canTransferFiles(): boolean {
    return !this.policy.viewOnly && this.policy.enableFileTransfer;
  }

  canReceiveClipboard(): boolean {
    return !this.policy.viewOnly && !this.policy.disableClipboard;
  }
}

export interface SecurityPolicyOptionsReader {
  resolveOptionBool(name: string, peerId?: string): boolean;
}

export function createDefaultSecurityPolicy(): SessionSecurityPolicy {
  return {
    viewOnly: false,
    disableKeyboard: false,
    disableClipboard: false,
    disableAudio: false,
    enableFileTransfer: false,
    lockAfterSessionEnd: false,
    showRemoteCursor: false,
    showMyCursor: false,
    followRemoteCursor: false,
    followRemoteWindow: false
  };
}

export function resolveSecurityPolicyFromReader(
  reader: SecurityPolicyOptionsReader,
  peerId?: string
): SessionSecurityPolicy {
  const viewOnly = reader.resolveOptionBool('view-only', peerId);
  let disableKeyboard = reader.resolveOptionBool('disable-keyboard', peerId);
  let disableClipboard = reader.resolveOptionBool('disable-clipboard', peerId);
  const disableAudio = reader.resolveOptionBool('disable-audio', peerId);
  let enableFileTransfer = reader.resolveOptionBool('enable-file-copy-paste', peerId);
  let lockAfterSessionEnd = reader.resolveOptionBool('lock-after-session-end', peerId);
  let showRemoteCursor = reader.resolveOptionBool('show-remote-cursor', peerId);
  let showMyCursor = reader.resolveOptionBool('show-my-cursor', peerId);
  const followRemoteCursor = reader.resolveOptionBool('follow-remote-cursor', peerId);
  const followRemoteWindow = reader.resolveOptionBool('follow-remote-window', peerId);

  if (viewOnly) {
    disableKeyboard = true;
    disableClipboard = true;
    enableFileTransfer = false;
    lockAfterSessionEnd = false;
    showRemoteCursor = true;
    showMyCursor = false;
  }

  return {
    viewOnly,
    disableKeyboard,
    disableClipboard,
    disableAudio,
    enableFileTransfer,
    lockAfterSessionEnd,
    showRemoteCursor,
    showMyCursor,
    followRemoteCursor,
    followRemoteWindow
  };
}
