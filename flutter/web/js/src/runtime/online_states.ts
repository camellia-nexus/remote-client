export function decodeOnlineStates(
  states: Uint8Array | undefined,
  ids: string[]
): [string[], string[]] {
  if (ids.length === 0) {
    return [[], []];
  }
  const expectedBytes = Math.ceil(ids.length / 8);
  if (!states || states.length < expectedBytes) {
    throw new Error(
      `Malformed online states response: expected at least ${expectedBytes} bytes for ${ids.length} peers, got ${
        states ? states.length : 0
      }`
    );
  }
  const onlines: string[] = [];
  const offlines: string[] = [];
  for (let i = 0; i < ids.length; i++) {
    const byteIndex = Math.floor(i / 8);
    const bitValue = 0x01 << (7 - (i % 8));
    if ((states[byteIndex] & bitValue) === bitValue) {
      onlines.push(ids[i]);
    } else {
      offlines.push(ids[i]);
    }
  }
  return [onlines, offlines];
}
