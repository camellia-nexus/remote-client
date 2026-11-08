declare module 'fzstd' {
  export function decompress(data: Uint8Array, buf?: Uint8Array): Uint8Array;
  export type ZstdStreamHandler = (data: Uint8Array, final?: boolean) => unknown;
  export class Decompress {
    constructor(ondata?: ZstdStreamHandler);
    push(chunk: Uint8Array, final?: boolean): void;
    ondata: ZstdStreamHandler;
  }
}

