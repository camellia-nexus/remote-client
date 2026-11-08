import * as fzstd from 'fzstd';

/**
 * Safely decompress Zstandard data with a strict maximum output byte budget.
 * Validates the frame header (content size and window size) if present, and
 * uses streaming decompression to immediately halt and reject if decompressed
 * output exceeds maxOutputBytes.
 */
export function safeZstdDecompress(
  data: Uint8Array,
  maxOutputBytes: number
): Uint8Array {
  if (!data || data.byteLength === 0) {
    return new Uint8Array(0);
  }
  if (maxOutputBytes <= 0 || !Number.isFinite(maxOutputBytes)) {
    throw new Error(`Invalid maxOutputBytes budget: ${maxOutputBytes}`);
  }

  // Inspect Zstandard frame header if magic number matches (0xFD2FB528 in little-endian)
  if (
    data.byteLength >= 5 &&
    data[0] === 0x28 &&
    data[1] === 0xb5 &&
    data[2] === 0x2f &&
    data[3] === 0xfd
  ) {
    const flg = data[4];
    if ((flg & 8) !== 0) {
      throw new Error('Invalid zstd frame header (reserved bit set)');
    }
    const ss = (flg >> 5) & 1;
    const df = flg & 3;
    const fcf = flg >> 6;
    let bt = 6 - ss;
    const db = df === 3 ? 4 : df;
    bt += db;
    const fsb = fcf ? 1 << fcf : ss;
    if (fsb > 0 && data.byteLength >= bt + fsb) {
      let fss = 0;
      for (let i = 0; i < fsb; i++) {
        fss += data[bt + i] * Math.pow(256, i);
      }
      if (fcf === 1) {
        fss += 256;
      }
      if (fss > maxOutputBytes) {
        throw new Error(
          `Zstd declared frame content size exceeds budget (${fss} > ${maxOutputBytes})`
        );
      }
    }
    if (!ss && data.byteLength >= 6) {
      const windowByte = data[5];
      const exponent = 10 + (windowByte >> 3);
      if (exponent > 30) {
        throw new Error('Zstd window size exponent too large');
      }
      const wb = 1 << exponent;
      const ws = wb + (wb >> 3) * (windowByte & 7);
      // Window size exceeding max budget (with minimum sanity headroom)
      if (ws > Math.max(maxOutputBytes, 16 * 1024 * 1024)) {
        throw new Error(
          `Zstd window size exceeds allowed budget (${ws} > ${maxOutputBytes})`
        );
      }
    }
  }

  const chunks: Uint8Array[] = [];
  let totalBytes = 0;
  const decompressor = new fzstd.Decompress((chunk) => {
    totalBytes += chunk.byteLength;
    if (totalBytes > maxOutputBytes) {
      throw new Error(
        `Zstd decompressed output exceeded budget (${totalBytes} > ${maxOutputBytes})`
      );
    }
    chunks.push(chunk);
  });

  decompressor.push(data, true);

  if (chunks.length === 0) {
    return new Uint8Array(0);
  }
  if (chunks.length === 1) {
    return chunks[0];
  }
  const result = new Uint8Array(totalBytes);
  let pos = 0;
  for (const chunk of chunks) {
    result.set(chunk, pos);
    pos += chunk.byteLength;
  }
  return result;
}
