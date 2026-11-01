import assert from 'node:assert/strict';
import test from 'node:test';

import { hbb } from '../src/proto/generated.js';
import { decodeOnlineStates } from '../src/runtime/online_states.ts';

test('clipboard file-content codecs preserve unsigned native fields', () => {
  const request = hbb.CliprdrFileContentsRequest.decode(
    hbb.CliprdrFileContentsRequest.encode({
      streamId: 0xffff_ffff,
      listIndex: 0xffff_fffe,
      dwFlags: 2,
      nPositionLow: 0xffff_ffff,
      nPositionHigh: 0xffff_ffff,
      cbRequested: 0xffff_ffff,
      haveClipDataId: true,
      clipDataId: 0xffff_fffd
    }).finish()
  );
  assert.equal(request.streamId, 0xffff_ffff);
  assert.equal(request.listIndex, 0xffff_fffe);
  assert.equal(request.nPositionLow, 0xffff_ffff);
  assert.equal(request.nPositionHigh, 0xffff_ffff);
  assert.equal(request.cbRequested, 0xffff_ffff);
  assert.equal(request.clipDataId, 0xffff_fffd);

  const response = hbb.CliprdrFileContentsResponse.decode(
    hbb.CliprdrFileContentsResponse.encode({
      msgFlags: 0xffff_ffff,
      streamId: 0xffff_fffc,
      requestedData: new Uint8Array([1, 2, 3])
    }).finish()
  );
  assert.equal(response.msgFlags, 0xffff_ffff);
  assert.equal(response.streamId, 0xffff_fffc);
  assert.deepEqual(Array.from(response.requestedData), [1, 2, 3]);
});

test('web file transfer advertises version 2 and preserves byte offsets', () => {
  const login = hbb.LoginRequest.decode(
    hbb.LoginRequest.encode({ fileTransferProtocolVersion: 2 }).finish()
  );
  assert.equal(login.fileTransferProtocolVersion, 2);

  const confirm = hbb.FileTransferSendConfirmRequest.decode(
    hbb.FileTransferSendConfirmRequest.encode(
      hbb.FileTransferSendConfirmRequest.fromObject({
        id: 7,
        fileNum: 1,
        offsetBytes: '4294967297'
      })
    ).finish()
  );
  const object = hbb.FileTransferSendConfirmRequest.toObject(confirm, {
    longs: String,
    oneofs: true
  });
  assert.equal(object.offsetBytes, '4294967297');
  assert.equal(object.union, 'offsetBytes');
});

test('decodeOnlineStates validates bounds and rejects truncated responses (PROTO-002)', () => {
  // Empty IDs -> empty
  assert.deepEqual(decodeOnlineStates(undefined, []), [[], []]);
  assert.deepEqual(decodeOnlineStates(new Uint8Array([]), []), [[], []]);

  // 1 ID, empty or missing states -> throws error
  assert.throws(
    () => decodeOnlineStates(undefined, ['peer1']),
    /Malformed online states response/
  );
  assert.throws(
    () => decodeOnlineStates(new Uint8Array([]), ['peer1']),
    /Malformed online states response/
  );

  // 1 ID, 1 byte -> parses correctly
  const [on1, off1] = decodeOnlineStates(new Uint8Array([0b1000_0000]), ['peer1']);
  assert.deepEqual(on1, ['peer1']);
  assert.deepEqual(off1, []);

  const [on2, off2] = decodeOnlineStates(new Uint8Array([0b0000_0000]), ['peer1']);
  assert.deepEqual(on2, []);
  assert.deepEqual(off2, ['peer1']);

  // 9 IDs, 1 byte -> requires 2 bytes -> throws error
  const ids9 = Array.from({ length: 9 }, (_, i) => `peer${i}`);
  assert.throws(
    () => decodeOnlineStates(new Uint8Array([0xff]), ids9),
    /expected at least 2 bytes for 9 peers, got 1/
  );

  // 9 IDs, 2 bytes -> valid
  const [on9, off9] = decodeOnlineStates(
    new Uint8Array([0b1010_1010, 0b1000_0000]),
    ids9
  );
  assert.deepEqual(on9, ['peer0', 'peer2', 'peer4', 'peer6', 'peer8']);
  assert.deepEqual(off9, ['peer1', 'peer3', 'peer5', 'peer7']);

  // 256 IDs, 31 bytes -> requires 32 bytes -> throws error
  const ids256 = Array.from({ length: 256 }, (_, i) => `peer${i}`);
  assert.throws(
    () => decodeOnlineStates(new Uint8Array(31), ids256),
    /expected at least 32 bytes for 256 peers, got 31/
  );

  // 256 IDs, 32 bytes -> valid
  const fullBytes = new Uint8Array(32).fill(0xff);
  const [on256, off256] = decodeOnlineStates(fullBytes, ids256);
  assert.equal(on256.length, 256);
  assert.equal(off256.length, 0);
});
