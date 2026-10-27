const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { spawn, spawnSync } = require('node:child_process');
const helper = path.resolve(process.argv[2]);
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'top-snapshot-'));
const context = vm.createContext({ ArrayBuffer, DataView, Uint8Array, TextDecoder, BigInt, Number,
  document: { hidden: true }, window: { addEventListener() {} }, setTimeout() {}, clearTimeout() {} });
vm.runInContext(fs.readFileSync(path.join(__dirname, '../Resources/TopWeb/environments.js'), 'utf8'), context);
const decode = buffer => context.decodeEnvironmentSnapshot(Uint8Array.from(buffer).buffer);
let registry;
try {
  const values = ['registered-test', 'Container café', 'docker', 'snapshot-container', 'running', 'test', '', '', 'snapshot-container'];
  const data = Buffer.alloc(120); const strings = [];
  let size = data.length;
  for (const [offset, value] of [[32, ''], ...values.map((value, index) => [48 + index * 8, value])]) {
    const bytes = Buffer.from(value); data.writeUInt32LE(size, offset); data.writeUInt32LE(bytes.length, offset + 4);
    strings.push(bytes); size += bytes.length;
  }
  for (const [offset, value] of [[0,0x4445534f],[4,1],[8,size],[12,1],[16,72],[20,48],[24,120]]) data.writeUInt32LE(value,offset);
  fs.writeFileSync(path.join(root,'registry.bin'),Buffer.concat([data,...strings]));
  registry = spawn('python3', [path.join(__dirname,'../Helper/test_registry_server.py'), path.join(root,'registry.sock'), path.join(root,'registry.bin')], {stdio:'inherit'});
  for (let i=0; i<100 && !fs.existsSync(path.join(root,'registry.sock.ready')); i++) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,50);
  assert(fs.existsSync(path.join(root,'registry.sock.ready')));
  fs.writeFileSync(path.join(root, 'docker'), `#!${process.execPath}
const {spawnSync} = require('node:child_process');
let args = process.argv.slice(2);
if (args[0] === '--host') args = args.slice(2);
if (args[0] === 'ps') {
 throw new Error('helper must not list containers');
} else if (args[0] === 'exec') {
 if (process.env.TEST_BAD_HELPER) process.stdout.write('invalid protocol');
 else process.exit(spawnSync(process.env.TEST_HELPER, ['serve'], {stdio:'inherit'}).status ?? 1);
} else process.exit(2);
`, { mode: 0o755 });
  const env = { ...process.env, PATH: root, TEST_HELPER: path.resolve(process.argv[3]), OUTERSHELLD_API_SOCKET: path.join(root,'registry.sock') };
  const run = extra => {
    const result = spawnSync(helper, [], { input:Buffer.alloc(0), env: { ...env, ...extra }, maxBuffer: 20 * 1024 * 1024, timeout: 30000 });
    assert.equal(result.status, 0, String(result.stderr));
    return result.stdout;
  };
  const bytes = run({});
  const snapshot = decode(bytes);
  assert.equal(snapshot.targets[0].id, 'host');
  const container = snapshot.targets.find(target => target.container === 'snapshot-container');
  assert.equal(container.name, 'Container café');
  assert(snapshot.processes.some(process => process.target === 'host'));
  assert(snapshot.processes.some(process => process.target === container.id && process.hostPID === 0));
  assert(!snapshot.errors.some(error => error.runtime === container.name || error.runtime.startsWith('docker')), String(snapshot.errors.map(error => error.runtime + ': ' + error.error)));
  assert(snapshot.time > 0 && snapshot.ticks > 0);
  for (const [offset, value] of [[0,0], [4,99], [8,0], [16,0xffffffff], [20,0], [36,96], [52,0xffffffff], [72,0]]) {
    const changed = Buffer.from(bytes); changed.writeUInt32LE(value, offset);
    assert.throws(() => decode(changed), /Invalid environment/);
  }
  assert.throws(() => decode(bytes.subarray(0, 79)), /size/);
  assert.throws(() => decode(bytes.subarray(0, bytes.length - 1)), /header/);
  const processOffset = bytes.readUInt32LE(32);
  for (const [relative, value] of [[96,0xffffffff], [44,3], [64,0xffffffff]]) {
    const changed = Buffer.from(bytes); changed.writeUInt32LE(value, processOffset + relative);
    assert.throws(() => decode(changed), /Invalid environment/);
  }
  const failed = decode(run({ TEST_BAD_HELPER: '1' }));
  assert(failed.processes.some(process => process.target === 'host'));
  assert(failed.errors.some(error => error.error.includes('outer-top-helper')));
  const message = Buffer.from('Process collection failed');
  const error = Buffer.alloc(80 + message.length);
  for (const [offset, value] of [[0,0x5054454f],[4,1],[8,error.length],[12,1],[20,80],[24,56],
    [32,80],[36,112],[44,80],[48,16],[52,80],[72,80],[76,message.length]]) error.writeUInt32LE(value, offset);
  message.copy(error,80);
  assert.throws(() => decode(error), /Process collection failed/);
  console.log('PASS: native helper → binary snapshot → browser decoder; container fallback, partial failures, malformed records and errors');
} finally { if (registry) registry.kill(); fs.rmSync(root, { recursive: true, force: true }); }
