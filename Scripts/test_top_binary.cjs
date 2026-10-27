const fs = require('node:fs'), vm = require('node:vm'), path = require('node:path'), assert = require('node:assert/strict');
const context = vm.createContext({ArrayBuffer,DataView,Uint8Array,TextDecoder,BigInt,Number,document:{hidden:true},window:{addEventListener(){}},setTimeout(){},clearTimeout(){}});
vm.runInContext(fs.readFileSync(path.join(__dirname,'../Resources/TopWeb/environments.js'),'utf8'),context);
const bytes = name => fs.readFileSync(path.join(process.argv[2],name));
const decode = (name,data) => context[name](Uint8Array.from(data).buffer);
const detail = decode('decodeTopProcessDetail',bytes('detail.bin')).process;
assert.equal(detail.pid,123);assert.equal(detail.command,'runner "雪"\n--test');assert.equal(detail.cpuPercent,12.5);
assert.equal(detail.openFiles[0].name,'/tmp/雪 café\n"file"');assert.equal(detail.openFilesError,'Some files unavailable');
const samples=decode('decodeTopCPUHistory',bytes('history.bin')).samples;
assert.equal(samples.length,1);assert.equal(samples[0].idlePercent,62.5);
assert.equal(decode('decodeTopCPUHistory',bytes('empty-history.bin')).samples.length,0);
assert.equal(decode('decodeTopProcessDetail',bytes('empty-files.bin')).process.openFiles.length,0);
for (const offset of [0,4,8,12,16,20,24,88]) {
 const data=Buffer.from(bytes('detail.bin'));data.writeUInt32LE(0xffffffff,offset);
 assert.throws(()=>decode('decodeTopProcessDetail',data));
}
for (const offset of [0,4,8,12,16,20,24,40]) {
 const data=Buffer.from(bytes('history.bin'));data.writeUInt32LE(0xffffffff,offset);
 assert.throws(()=>decode('decodeTopCPUHistory',data));
}
console.log('PASS: JavaScript binary history/detail decoding, UTF-8 and malformed offsets');
