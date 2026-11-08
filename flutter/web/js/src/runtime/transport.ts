import { Logger } from '../core/logger.ts';
import { SecretBoxCipher } from './crypto.ts';

export type TransportState = 'idle' | 'connecting' | 'open' | 'closed' | 'error';

export const MAX_FRAME_BYTES = 16 * 1024 * 1024; // 16 MiB

type MessageHandler = (data: Uint8Array) => void;
type CloseHandler = (event: CloseEvent) => void;

type DrainWaiter = {
  target: number;
  timeoutAt: number;
  resolve: () => void;
  reject: (err: Error) => void;
};

export class WebSocketTransport {
  private socket?: WebSocket;
  private state: TransportState = 'idle';
  private readonly logger: Logger;
  private readonly handlers: MessageHandler[] = [];
  private readonly closeHandlers: CloseHandler[] = [];
  private cipher?: SecretBoxCipher;
  private lastSendDropLogTs = 0;
  private readonly drainWaiters: DrainWaiter[] = [];
  private drainIntervalTimer?: number;

  constructor(scope = 'transport') {
    this.logger = new Logger(scope);
  }

  getState(): TransportState {
    return this.state;
  }

  getBufferedAmount(): number {
    return this.socket ? (this.socket.bufferedAmount || 0) : 0;
  }

  async drainBackpressure(
    targetBytes = 256 * 1024,
    timeoutMs = 15000
  ): Promise<void> {
    if (this.getBufferedAmount() <= targetBytes) {
      return;
    }
    if (
      !this.socket ||
      this.state !== 'open' ||
      this.socket.readyState !== WebSocket.OPEN
    ) {
      throw new Error('Transport is not open for backpressure drain');
    }
    return new Promise((resolve, reject) => {
      const waiter: DrainWaiter = {
        target: targetBytes,
        timeoutAt: timeoutMs > 0 ? Date.now() + timeoutMs : Infinity,
        resolve,
        reject
      };
      this.drainWaiters.push(waiter);
      this.ensureDrainPolling();
    });
  }

  private ensureDrainPolling(): void {
    if (this.drainIntervalTimer !== undefined || this.drainWaiters.length === 0) {
      return;
    }
    const timerScope = typeof window !== 'undefined' ? window : globalThis;
    this.drainIntervalTimer = timerScope.setInterval(() => {
      this.checkDrainWaiters();
    }, 20) as unknown as number;
  }

  private checkDrainWaiters(): void {
    if (
      !this.socket ||
      this.state !== 'open' ||
      this.socket.readyState !== WebSocket.OPEN
    ) {
      this.clearDrainWaiters(
        new Error('Transport closed while waiting for backpressure drain')
      );
      return;
    }
    const current = this.getBufferedAmount();
    const now = Date.now();
    for (let i = this.drainWaiters.length - 1; i >= 0; i--) {
      const waiter = this.drainWaiters[i];
      if (current <= waiter.target) {
        this.drainWaiters.splice(i, 1);
        waiter.resolve();
      } else if (now >= waiter.timeoutAt) {
        this.drainWaiters.splice(i, 1);
        waiter.reject(
          new Error(
            `Backpressure drain timed out (bufferedAmount=${current}, target=${waiter.target})`
          )
        );
      }
    }
    if (this.drainWaiters.length === 0 && this.drainIntervalTimer !== undefined) {
      const timerScope = typeof window !== 'undefined' ? window : globalThis;
      timerScope.clearInterval(this.drainIntervalTimer);
      this.drainIntervalTimer = undefined;
    }
  }

  private clearDrainWaiters(err: Error): void {
    if (this.drainIntervalTimer !== undefined) {
      const timerScope = typeof window !== 'undefined' ? window : globalThis;
      timerScope.clearInterval(this.drainIntervalTimer);
      this.drainIntervalTimer = undefined;
    }
    const waiters = this.drainWaiters.splice(0, this.drainWaiters.length);
    for (const waiter of waiters) {
      waiter.reject(err);
    }
  }

  onMessage(handler: MessageHandler): () => void {
    this.handlers.push(handler);
    return () => {
      const index = this.handlers.indexOf(handler);
      if (index >= 0) {
        this.handlers.splice(index, 1);
      }
    };
  }

  onClose(handler: CloseHandler): () => void {
    this.closeHandlers.push(handler);
    return () => {
      const index = this.closeHandlers.indexOf(handler);
      if (index >= 0) {
        this.closeHandlers.splice(index, 1);
      }
    };
  }

  setCipher(cipher?: SecretBoxCipher): void {
    this.cipher = cipher;
  }

  handleSocketMessage(event: { data: unknown }): void {
    if (!this.socket || this.state !== 'open') {
      return;
    }
    const socket = this.socket;
    if (typeof event.data === 'string') {
      if (this.cipher) {
        this.logger.error('Received unexpected text frame on encrypted transport');
        this.state = 'error';
        this.cipher = undefined;
        try {
          socket.close(1003, 'Unexpected text frame on encrypted transport');
        } catch {
          // noop
        }
        this.clearDrainWaiters(new Error('Transport received invalid text frame'));
      }
      return;
    }
    if (event.data instanceof ArrayBuffer) {
      if (event.data.byteLength > MAX_FRAME_BYTES) {
        this.logger.error(
          `WebSocket frame exceeded maximum size (${event.data.byteLength} > ${MAX_FRAME_BYTES})`
        );
        this.state = 'error';
        this.cipher = undefined;
        try {
          socket.close(1009, 'Frame size limit exceeded');
        } catch {
          // noop
        }
        this.clearDrainWaiters(new Error('Transport frame exceeded limit'));
        return;
      }
      let payload = new Uint8Array(event.data) as Uint8Array;
      if (this.cipher) {
        try {
          payload = this.cipher.decrypt(payload) as Uint8Array;
        } catch (err) {
          this.logger.error('Failed to decrypt WebSocket payload', err);
          this.state = 'error';
          this.cipher = undefined;
          try {
            socket.close(1002, 'Encrypted payload authentication failed');
          } catch {
            // noop
          }
          this.clearDrainWaiters(new Error('Transport decrypt failed'));
          return;
        }
        if (payload.byteLength > MAX_FRAME_BYTES) {
          this.logger.error(
            `Decrypted WebSocket payload exceeded maximum size (${payload.byteLength} > ${MAX_FRAME_BYTES})`
          );
          this.state = 'error';
          this.cipher = undefined;
          try {
            socket.close(1009, 'Frame size limit exceeded');
          } catch {
            // noop
          }
          this.clearDrainWaiters(new Error('Decrypted payload exceeded limit'));
          return;
        }
      }
      for (const handler of this.handlers) {
        handler(payload);
      }
    }
  }

  async connect(url: string, timeoutMs = 10000): Promise<void> {
    if (
      this.socket &&
      this.state === 'open' &&
      this.socket.readyState === WebSocket.OPEN
    ) {
      return;
    }
    this.cipher = undefined;
    const previous = this.socket;
    this.socket = undefined;
    this.clearDrainWaiters(new Error('WebSocket connection superseded'));
    if (previous && previous.readyState < WebSocket.CLOSING) {
      try {
        previous.close();
      } catch {
        // noop
      }
    }
    this.state = 'connecting';
    return new Promise((resolve, reject) => {
      let settled = false;
      let timer: number | undefined;
      const finish = (ok: boolean, err?: unknown) => {
        if (settled) {
          return;
        }
        settled = true;
        if (timer !== undefined) {
          window.clearTimeout(timer);
          timer = undefined;
        }
        if (ok) {
          resolve();
        } else {
          reject(err);
        }
      };
      try {
        const socket = new WebSocket(url);
        this.socket = socket;
        socket.binaryType = 'arraybuffer';
        socket.onopen = () => {
          if (this.socket !== socket) {
            try {
              socket.close();
            } catch {
              // noop
            }
            finish(false, new Error('WebSocket connection superseded'));
            return;
          }
          this.state = 'open';
          this.logger.info(`WebSocket connected: ${url}`);
          finish(true);
        };
        socket.onerror = (event) => {
          if (this.socket === socket) {
            this.state = 'error';
          }
          this.logger.error(`WebSocket error: ${url}`);
          this.clearDrainWaiters(new Error('WebSocket error'));
          finish(false, event);
        };
        socket.onclose = (event) => {
          if (this.socket !== socket) {
            return;
          }
          this.state = 'closed';
          this.socket = undefined;
          this.cipher = undefined;
          this.logger.warn(`WebSocket closed: ${url}`);
          this.clearDrainWaiters(new Error('WebSocket closed'));
          for (const handler of this.closeHandlers) {
            handler(event);
          }
          if (!settled) {
            finish(
              false,
              new Error(
                `WebSocket closed before ready (code=${event.code}, reason=${event.reason || 'n/a'})`
              )
            );
          }
        };
        socket.onmessage = (event) => {
          if (this.socket !== socket) {
            return;
          }
          this.handleSocketMessage(event);
        };
        if (timeoutMs > 0) {
          timer = window.setTimeout(() => {
            if (settled) {
              return;
            }
            if (this.socket === socket) {
              this.state = 'error';
              this.socket = undefined;
            }
            this.logger.warn(`WebSocket connect timeout: ${url}`);
            this.clearDrainWaiters(new Error('WebSocket connect timeout'));
            try {
              socket.close();
            } catch {
              // noop
            }
            finish(false, new Error(`WebSocket connect timeout: ${timeoutMs}ms`));
          }, timeoutMs);
        }
      } catch (err) {
        this.state = 'error';
        this.clearDrainWaiters(new Error('WebSocket connect failed'));
        finish(false, err);
      }
    });
  }

  send(data: Uint8Array): boolean {
    const socket = this.socket;
    if (
      !socket ||
      this.state !== 'open' ||
      socket.readyState !== WebSocket.OPEN
    ) {
      const now = Date.now();
      if (now - this.lastSendDropLogTs >= 5000) {
        const readyState = socket ? socket.readyState : -1;
        this.logger.warn(
          `send() dropped because socket not open (state=${this.state}, readyState=${readyState})`
        );
        this.lastSendDropLogTs = now;
      }
      return false;
    }
    try {
      const payload = this.cipher ? this.cipher.encrypt(data) : data;
      // TypeScript 6 narrows WebSocket.send() to ArrayBuffer-backed views.
      // Copy to a fresh Uint8Array so the backing buffer is always ArrayBuffer.
      socket.send(payload.slice());
      return true;
    } catch (err) {
      this.state = 'error';
      this.cipher = undefined;
      this.logger.warn('send() failed', err);
      try {
        socket.close(1011, 'Encrypted transport failure');
      } catch {
        // noop
      }
      this.clearDrainWaiters(new Error('Transport send failed'));
      return false;
    }
  }

  close(): void {
    this.clearDrainWaiters(new Error('Transport closed'));
    const socket = this.socket;
    this.socket = undefined;
    this.cipher = undefined;
    if (socket && socket.readyState < WebSocket.CLOSING) {
      socket.close();
    }
    this.state = 'closed';
  }
}
