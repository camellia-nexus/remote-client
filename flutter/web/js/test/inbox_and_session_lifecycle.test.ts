import assert from 'node:assert/strict';
import test from 'node:test';

import {
  MessageInbox,
  MAX_INBOX_QUEUE_MESSAGES,
  MAX_INBOX_QUEUE_BYTES,
  type InboxTransport
} from '../src/runtime/inbox.ts';

function createMockTransport(): {
  transport: InboxTransport;
  dispatchMessage: (data: Uint8Array) => void;
} {
  let handler: ((data: Uint8Array) => void) | undefined;
  const mockTransport: InboxTransport = {
    onMessage(fn: (data: Uint8Array) => void) {
      handler = fn;
      return () => {
        handler = undefined;
      };
    }
  };

  return {
    transport: mockTransport,
    dispatchMessage: (data: Uint8Array) => {
      if (handler) {
        handler(data);
      }
    }
  };
}

test('MessageInbox delivers queued messages in FIFO order', async () => {
  const { transport, dispatchMessage } = createMockTransport();
  const inbox = new MessageInbox(transport);

  dispatchMessage(new Uint8Array([1, 2, 3]));
  dispatchMessage(new Uint8Array([4, 5, 6]));

  const first = await inbox.next(1000);
  const second = await inbox.next(1000);

  assert.deepEqual(Array.from(first), [1, 2, 3]);
  assert.deepEqual(Array.from(second), [4, 5, 6]);

  inbox.close();
});

test('MessageInbox cleans up timed out waiters without leaking or swallowing messages (STATE-016)', async () => {
  const { transport, dispatchMessage } = createMockTransport();
  const inbox = new MessageInbox(transport);

  // Waiter 1 times out quickly
  await assert.rejects(
    async () => {
      await inbox.next(50);
    },
    { message: 'timeout waiting for message' }
  );

  assert.equal(inbox.getPendingWaitersCount(), 0);

  // Next waiter should receive the message without being swallowed by the old waiter
  const nextPromise = inbox.next(1000);
  assert.equal(inbox.getPendingWaitersCount(), 1);

  dispatchMessage(new Uint8Array([9, 9, 9]));
  const received = await nextPromise;
  assert.deepEqual(Array.from(received), [9, 9, 9]);
  assert.equal(inbox.getPendingWaitersCount(), 0);

  inbox.close();
});

test('MessageInbox close() immediately rejects all pending waiters and prevents new reads (STATE-016)', async () => {
  const { transport } = createMockTransport();
  const inbox = new MessageInbox(transport);

  const p1 = inbox.next(10000);
  const p2 = inbox.next(10000);

  assert.equal(inbox.getPendingWaitersCount(), 2);
  inbox.close();
  assert.equal(inbox.isClosed(), true);
  assert.equal(inbox.getPendingWaitersCount(), 0);

  await assert.rejects(p1, { message: 'Inbox closed' });
  await assert.rejects(p2, { message: 'Inbox closed' });

  await assert.rejects(
    async () => {
      await inbox.next(1000);
    },
    { message: 'Inbox is closed' }
  );
});

test('MessageInbox enforces queue bounds against memory bloat (STATE-016)', () => {
  const { transport, dispatchMessage } = createMockTransport();
  const inbox = new MessageInbox(transport);

  // Exceed MAX_INBOX_QUEUE_MESSAGES
  assert.throws(
    () => {
      for (let i = 0; i < MAX_INBOX_QUEUE_MESSAGES + 10; i++) {
        dispatchMessage(new Uint8Array([i % 256]));
      }
    },
    /Inbox queue limit exceeded/
  );

  assert.equal(inbox.isClosed(), true);
});

test('MessageInbox pushFront enforces byte limits and preserves FIFO prepend (STATE-016)', async () => {
  const { transport } = createMockTransport();
  const inbox = new MessageInbox(transport);

  inbox.pushFront(new Uint8Array([10, 20]));
  inbox.pushFront(new Uint8Array([30, 40]));

  const first = await inbox.next(500);
  const second = await inbox.next(500);

  assert.deepEqual(Array.from(first), [30, 40]);
  assert.deepEqual(Array.from(second), [10, 20]);

  // Exceed byte limit
  const hugeData = new Uint8Array(MAX_INBOX_QUEUE_BYTES + 1);
  assert.throws(
    () => {
      inbox.pushFront(hugeData);
    },
    /Inbox queue limit exceeded/
  );

  assert.equal(inbox.isClosed(), true);
});
