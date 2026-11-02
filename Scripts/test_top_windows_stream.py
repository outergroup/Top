"""Check a frame emitted by TopHostTests with both production frontend decoders."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
frame = str(Path(sys.argv[1]).resolve())
web = str(root / 'Resources/TopWeb/top.js')
script = r'''
const fs = require('fs'), vm = require('vm'), assert = require('assert/strict');
const source = fs.readFileSync(WEB, 'utf8');
const context = vm.createContext({TextDecoder, Uint8Array, DataView, decoder:new TextDecoder(), MAX_FRAME_ROWS:1000000});
vm.runInContext(source.slice(source.indexOf('  function readU64('), source.indexOf('  function concatenate(')), context);
context.bytes = new Uint8Array(fs.readFileSync(FRAME));
const result = vm.runInContext('parseFrame(bytes)', context);
assert.equal(result.consumed, context.bytes.length);
assert.equal(result.frame.entries.length, 3);
assert.equal(result.frame.entries[1].pid, 0x40000000);
assert.equal(result.frame.entries[1].displayPID, 10);
assert.equal(result.frame.metrics.logicalCPUCount, 8);
for(let end=0; end<context.bytes.length; ++end) {
  context.partial = context.bytes.subarray(0,end);
  assert.equal(vm.runInContext('parseFrame(partial)',context), null);
}
context.bytes = new Uint8Array(fs.readFileSync(MOTION));
const motion = vm.runInContext('parseFrame(bytes)', context);
assert.equal(motion.consumed, context.bytes.length);
assert.equal(motion.frame.entries[0].previousIndex, 1);
assert.equal(motion.frame.entries[0].displayPID, 10);
assert.equal(motion.frame.additional.length, 1);
assert.equal(motion.frame.additional[0][0], 2);
assert.equal(motion.frame.additional[0][1].previousIndex, 0);
for(let end=0; end<context.bytes.length; ++end) {
  context.partial = context.bytes.subarray(0,end);
  assert.equal(vm.runInContext('parseFrame(partial)',context), null);
}
console.log('PASS HTML Windows frames, movement, outgoing rows, display PID and partial-frame boundaries');
'''.replace('WEB', json.dumps(web)).replace('FRAME));', json.dumps(frame) + '));').replace('MOTION', json.dumps(frame + '.motion'))
subprocess.run(['node', '-e', script], check=True)
source = (root / 'Frontend/FullSystemView/ProcessMonitorListContentController.swift').read_text()
code = ('import Foundation\n' + source[source.index('private struct SystemMetrics {'):source.index('private func formattedInteger(')]
        + source[source.index('private func readUInt8('):source.index('private struct ValueRange:')])
code += '''
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
guard let (frame, count) = parseFullViewportContents(data) else { fatalError("Decode failed") }
precondition(count == data.count && frame.entries.count == 3)
precondition(frame.entries[1].pid == 0x40000000 && frame.entries[1].displayPID == 10)
precondition(frame.systemMetrics?.logicalCpuCount == 8)
for end in 0..<data.count { precondition(parseFullViewportContents(data.prefix(end)) == nil) }
let motionData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1] + ".motion"))
guard let (motion, motionCount) = parseFullViewportContents(motionData) else { fatalError("Motion decode failed") }
precondition(motionCount == motionData.count && motion.entries.count == 1)
precondition(motion.entries[0].previousIndex == 1 && motion.entries[0].displayPID == 10)
precondition(motion.additionalEntries.count == 1)
precondition(motion.additionalEntries[0].0 == 2 && motion.additionalEntries[0].1.previousIndex == 0)
for end in 0..<motionData.count { precondition(parseFullViewportContents(motionData.prefix(end)) == nil) }
print("PASS outerframe Windows frames, movement, outgoing rows, display PID and partial-frame boundaries")
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / 'StreamTest.swift'
    path.write_text(code)
    subprocess.run(['swift', str(path), frame], check=True)
