export interface InboxTransport {
  onMessage(handler: (data: Uint8Array) => void): () => void;
}

export const MAX_INBOX_QUEUE_MESSAGES = 1000;
export const MAX_INBOX_QUEUE_BYTES = 16 * 1024 * 1024; // 16 MiB

interface InboxWaiter {
  readonly id: number;
  readonly resolve: (data: Uint8Array) => void;
  readonly reject: (err: Error) => void;
  timer: ReturnType<typeof setTimeout> | undefined;
  settled: boolean;
}

export class MessageInbox {
  private readonly queue: Uint8Array[] = [];
  private readonly waiters: InboxWaiter[] = [];
  private readonly unsubscribe: () => void;
  private nextWaiterId = 0;
  private totalQueueBytes = 0;
  private closed = false;

  constructor(transport: InboxTransport) {
    this.unsubscribe = transport.onMessage((data) => this.push(data));
  }

  next(timeoutMs = 15000): Promise<Uint8Array> {
    if (this.closed) {
      return Promise.reject(new Error('Inbox is closed'));
    }
    if (this.queue.length > 0) {
      const data = this.queue.shift()!;
      this.totalQueueBytes = Math.max(0, this.totalQueueBytes - data.byteLength);
      return Promise.resolve(data);
    }
    return new Promise((resolve, reject) => {
      const waiterId = ++this.nextWaiterId;
      const waiter: InboxWaiter = {
        id: waiterId,
        resolve,
        reject,
        timer: undefined,
        settled: false
      };
      waiter.timer = setTimeout(() => {
        this.settleAndRemove(waiterId, (w) => {
          w.reject(new Error('timeout waiting for message'));
        });
      }, timeoutMs);
      this.waiters.push(waiter);
    });
  }

  close(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.unsubscribe();
    for (const waiter of this.waiters) {
      if (!waiter.settled) {
        waiter.settled = true;
        if (waiter.timer !== undefined) {
          clearTimeout(waiter.timer);
          waiter.timer = undefined;
        }
        waiter.reject(new Error('Inbox closed'));
      }
    }
    this.waiters.length = 0;
    this.queue.length = 0;
    this.totalQueueBytes = 0;
  }

  pushFront(data: Uint8Array): void {
    if (this.closed) {
      return;
    }
    if (
      this.queue.length >= MAX_INBOX_QUEUE_MESSAGES ||
      this.totalQueueBytes + data.byteLength > MAX_INBOX_QUEUE_BYTES
    ) {
      this.close();
      throw new Error(
        `Inbox queue limit exceeded: messages=${this.queue.length}, bytes=${this.totalQueueBytes}`
      );
    }
    this.queue.unshift(data);
    this.totalQueueBytes += data.byteLength;
  }

  isClosed(): boolean {
    return this.closed;
  }

  getPendingWaitersCount(): number {
    return this.waiters.length;
  }

  getQueueLength(): number {
    return this.queue.length;
  }

  getQueueBytes(): number {
    return this.totalQueueBytes;
  }

  private settleAndRemove(
    waiterId: number,
    action: (waiter: InboxWaiter) => void
  ): boolean {
    const idx = this.waiters.findIndex((w) => w.id === waiterId);
    if (idx === -1) {
      return false;
    }
    const [waiter] = this.waiters.splice(idx, 1);
    if (waiter.settled) {
      return false;
    }
    waiter.settled = true;
    if (waiter.timer !== undefined) {
      clearTimeout(waiter.timer);
      waiter.timer = undefined;
    }
    action(waiter);
    return true;
  }

  private push(data: Uint8Array): void {
    if (this.closed) {
      return;
    }
    while (this.waiters.length > 0) {
      const waiter = this.waiters.shift()!;
      if (!waiter.settled) {
        waiter.settled = true;
        if (waiter.timer !== undefined) {
          clearTimeout(waiter.timer);
          waiter.timer = undefined;
        }
        waiter.resolve(data);
        return;
      }
    }
    if (
      this.queue.length >= MAX_INBOX_QUEUE_MESSAGES ||
      this.totalQueueBytes + data.byteLength > MAX_INBOX_QUEUE_BYTES
    ) {
      this.close();
      throw new Error(
        `Inbox queue limit exceeded: messages=${this.queue.length}, bytes=${this.totalQueueBytes}`
      );
    }
    this.queue.push(data);
    this.totalQueueBytes += data.byteLength;
  }
}
