#!/usr/bin/env python3
import os,pathlib,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='top-binary-') as temporary:
 work=pathlib.Path(temporary)
 subprocess.run(['cc','-std=gnu17','-O1','-g','-fsanitize=address,undefined','-I',str(root/'Backend'),str(root/'Tests/TopBinaryPayloadTest.c'),str(root/'Backend/Environment.c'),'-framework','CoreFoundation','-lpthread','-lm','-o',str(work/'producer')],check=True)
 subprocess.run([str(work/'producer'),str(work)],check=True,env=dict(os.environ,UBSAN_OPTIONS='halt_on_error=1'))
 top=(root/'Frontend/TopContent.swift').read_text();detail=(root/'Frontend/ProcessView/ProcessDetailContentController.swift').read_text()
 source='import Foundation\n'+top[top.index('struct TopBinaryReader'):top.index('func makeSystemSymbolImage')]+detail[detail.index('private struct DetailOpenFileEntry'):detail.index('private struct ProcessDetailSnapshot')]
 source+='''
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try Data(contentsOf: root.appendingPathComponent("detail.bin"))
private let detail = try ProcessDetailResponse(data)
assert(detail.process.memoryKilobytes == 5432 && detail.process.residentMemoryKilobytes == 12345)
assert(detail.process.pid == 123 && detail.process.isKernelThread == true)
assert(detail.process.command == "runner \\"雪\\"\\n--test")
assert(detail.process.openFiles?.first?.name == "/tmp/雪 café\\n\\"file\\"")
assert(detail.process.openFilesError == "Some files unavailable")
assert(detail.process.cpuPercent == 12.5 && detail.process.virtualMemoryKilobytes == 98765)
let history = try TopCPUHistoryResponse(Data(contentsOf: root.appendingPathComponent("history.bin")))
assert(history.samples.count == 1 && history.samples[0].idlePercent == 62.5)
assert(try TopCPUHistoryResponse(Data(contentsOf: root.appendingPathComponent("empty-history.bin"))).samples.isEmpty)
assert(try ProcessDetailResponse(Data(contentsOf: root.appendingPathComponent("empty-files.bin"))).process.openFiles?.isEmpty == true)
for offset in [0, 4, 8, 12, 16, 20, 24, 88] {
 var changed = data; changed.replaceSubrange(offset..<(offset + 4), with: [255,255,255,255])
 assert((try? ProcessDetailResponse(changed)) == nil)
}
print("PASS: Swift binary history/detail/bootstrap decoding and malformed offsets")
'''
 # Swift's assert autoclosure cannot throw.
 source=source.replace('assert(try TopCPUHistoryResponse(Data(contentsOf: root.appendingPathComponent("empty-history.bin"))).samples.isEmpty)','let emptyHistory = try TopCPUHistoryResponse(Data(contentsOf: root.appendingPathComponent("empty-history.bin")))\nassert(emptyHistory.samples.isEmpty)').replace('assert(try ProcessDetailResponse(Data(contentsOf: root.appendingPathComponent("empty-files.bin"))).process.openFiles?.isEmpty == true)','private let emptyFiles = try ProcessDetailResponse(Data(contentsOf: root.appendingPathComponent("empty-files.bin")))\nassert(emptyFiles.process.openFiles?.isEmpty == true)')
 (work/'main.swift').write_text(source)
 subprocess.run(['swiftc',str(work/'main.swift'),'-o',str(work/'swift-test')],check=True)
 subprocess.run([str(work/'swift-test'),str(work)],check=True)
 subprocess.run(['node',str(root/'Scripts/test_top_binary.cjs'),str(work)],check=True)
