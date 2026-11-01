import assert from 'node:assert/strict';
import test from 'node:test';
import {
  createDefaultSecurityPolicy,
  resolveSecurityPolicyFromReader,
  type SecurityPolicyOptionsReader,
  SessionPolicyGuard
} from '../src/runtime/policy.ts';
import type { SessionSecurityPolicy } from '../src/runtime/types.ts';

test('SessionPolicyGuard gates operations when viewOnly is active', () => {
  const policy: SessionSecurityPolicy = {
    viewOnly: true,
    disableKeyboard: true,
    disableClipboard: true,
    disableAudio: false,
    enableFileTransfer: false,
    lockAfterSessionEnd: false,
    showRemoteCursor: true,
    showMyCursor: false,
    followRemoteCursor: false,
    followRemoteWindow: false
  };

  const guard = new SessionPolicyGuard(policy);
  assert.equal(guard.isViewOnly(), true);
  assert.equal(guard.canSendKeyboard(), false);
  assert.equal(guard.canSendMouse(), false);
  assert.equal(guard.canSendControl(), false);
  assert.equal(guard.canTransferFiles(), false);
  assert.equal(guard.canReceiveClipboard(), false);
});

test('SessionPolicyGuard allows standard input when viewOnly is false', () => {
  const policy: SessionSecurityPolicy = {
    viewOnly: false,
    disableKeyboard: false,
    disableClipboard: false,
    disableAudio: false,
    enableFileTransfer: true,
    lockAfterSessionEnd: true,
    showRemoteCursor: false,
    showMyCursor: true,
    followRemoteCursor: false,
    followRemoteWindow: false
  };

  const guard = new SessionPolicyGuard(policy);
  assert.equal(guard.isViewOnly(), false);
  assert.equal(guard.canSendKeyboard(), true);
  assert.equal(guard.canSendMouse(), true);
  assert.equal(guard.canSendControl(), true);
  assert.equal(guard.canTransferFiles(), true);
  assert.equal(guard.canReceiveClipboard(), true);
});

test('SessionPolicyGuard enforces individual disable toggles when viewOnly is false', () => {
  const policy: SessionSecurityPolicy = {
    viewOnly: false,
    disableKeyboard: true,
    disableClipboard: true,
    disableAudio: true,
    enableFileTransfer: false,
    lockAfterSessionEnd: false,
    showRemoteCursor: true,
    showMyCursor: false,
    followRemoteCursor: false,
    followRemoteWindow: false
  };

  const guard = new SessionPolicyGuard(policy);
  assert.equal(guard.canSendKeyboard(), false);
  assert.equal(guard.canReceiveClipboard(), false);
  assert.equal(guard.canTransferFiles(), false);
  // Mouse and control remain active if only keyboard/clipboard/file are disabled
  assert.equal(guard.canSendMouse(), true);
  assert.equal(guard.canSendControl(), true);

  // Update policy dynamically
  guard.updatePolicy({ disableKeyboard: false, enableFileTransfer: true });
  assert.equal(guard.canSendKeyboard(), true);
  assert.equal(guard.canTransferFiles(), true);
  assert.equal(guard.canReceiveClipboard(), false);
});

test('createDefaultSecurityPolicy returns expected secure defaults', () => {
  const def = createDefaultSecurityPolicy();
  assert.equal(def.viewOnly, false);
  assert.equal(def.disableKeyboard, false);
  assert.equal(def.disableClipboard, false);
  assert.equal(def.disableAudio, false);
  assert.equal(def.enableFileTransfer, false);
  assert.equal(def.lockAfterSessionEnd, false);
  assert.equal(def.showRemoteCursor, false);
  assert.equal(def.showMyCursor, false);
});

test('resolveSecurityPolicyFromReader resolves policy with atomic viewOnly derivation', () => {
  const options = new Map<string, boolean>();
  const reader: SecurityPolicyOptionsReader = {
    resolveOptionBool(name: string): boolean {
      return options.get(name) ?? false;
    }
  };

  // Default state
  const defaultPolicy = resolveSecurityPolicyFromReader(reader);
  assert.equal(defaultPolicy.viewOnly, false);
  assert.equal(defaultPolicy.disableKeyboard, false);
  assert.equal(defaultPolicy.disableClipboard, false);

  // Set view-only = true
  options.set('view-only', true);
  const viewOnlyPolicy = resolveSecurityPolicyFromReader(reader);
  assert.equal(viewOnlyPolicy.viewOnly, true);
  assert.equal(viewOnlyPolicy.disableKeyboard, true);
  assert.equal(viewOnlyPolicy.disableClipboard, true);
  assert.equal(viewOnlyPolicy.enableFileTransfer, false);
  assert.equal(viewOnlyPolicy.lockAfterSessionEnd, false);
  assert.equal(viewOnlyPolicy.showRemoteCursor, true);
  assert.equal(viewOnlyPolicy.showMyCursor, false);

  // Toggle view-only back off
  options.set('view-only', false);
  const restoredPolicy = resolveSecurityPolicyFromReader(reader);
  assert.equal(restoredPolicy.viewOnly, false);
  assert.equal(restoredPolicy.disableKeyboard, false);
  assert.equal(restoredPolicy.disableClipboard, false);
});

test('resolveSecurityPolicyFromReader resolves peer-specific security overrides', () => {
  const globalOptions = new Map<string, boolean>();
  const peerOptions = new Map<string, Map<string, boolean>>();

  const reader: SecurityPolicyOptionsReader = {
    resolveOptionBool(name: string, peerId?: string): boolean {
      if (peerId && peerOptions.has(peerId)) {
        const pMap = peerOptions.get(peerId)!;
        if (pMap.has(name)) {
          return pMap.get(name)!;
        }
      }
      return globalOptions.get(name) ?? false;
    }
  };

  const targetPeer = 'peer-test-123';
  const peerMap = new Map<string, boolean>();
  peerMap.set('disable-keyboard', true);
  peerMap.set('disable-clipboard', true);
  peerOptions.set(targetPeer, peerMap);

  const peerPolicy = resolveSecurityPolicyFromReader(reader, targetPeer);
  assert.equal(peerPolicy.disableKeyboard, true);
  assert.equal(peerPolicy.disableClipboard, true);
  assert.equal(peerPolicy.viewOnly, false);

  // Global policy for another peer remains unaffected
  const otherPolicy = resolveSecurityPolicyFromReader(reader, 'other-peer');
  assert.equal(otherPolicy.disableKeyboard, false);
  assert.equal(otherPolicy.disableClipboard, false);
});
