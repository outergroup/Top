function decodeEnvironmentSnapshot(buffer) {
  if (!(buffer instanceof ArrayBuffer) || buffer.byteLength < 80 || buffer.byteLength > 16 * 1024 * 1024) {
    throw new Error("Invalid environment snapshot size");
  }
  const view = new DataView(buffer);
  const bytes = new Uint8Array(buffer);
  const u32 = offset => view.getUint32(offset, true);
  const u64 = offset => {
    const value = view.getBigUint64(offset, true);
    if (value > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("Environment value exceeds numeric range");
    return Number(value);
  };
  if (u32(0) !== 0x5054454f || u32(4) !== 1 || u32(8) !== buffer.byteLength || u32(12) > 1 || u32(68)) {
    throw new Error("Invalid environment snapshot header");
  }
  const targetCount = u32(16), targetOffset = u32(20);
  const processCount = u32(28), processOffset = u32(32);
  const errorCount = u32(40), errorOffset = u32(44), variable = u32(52);
  if (targetOffset !== 80 || u32(24) !== 56 || u32(36) !== 112 || u32(48) !== 16 ||
      processOffset !== targetOffset + targetCount * 56 || errorOffset !== processOffset + processCount * 112 ||
      variable !== errorOffset + errorCount * 16 || variable > buffer.byteLength) {
    throw new Error("Invalid environment snapshot records");
  }
  const decoder = new TextDecoder();
  const text = field => {
    const offset = u32(field), length = u32(field + 4);
    if (offset < variable || offset > buffer.byteLength || length > buffer.byteLength - offset) {
      throw new Error("Invalid environment string reference");
    }
    const value = bytes.subarray(offset, offset + length);
    if (value.includes(0)) throw new Error("Invalid environment string");
    return decoder.decode(value);
  };
  const message = text(72);
  if (u32(12)) {
    if (targetCount || processCount || errorCount) throw new Error("Invalid environment error response");
    throw new Error(message || "Environment discovery failed");
  }
  if (!targetCount || message) throw new Error("Invalid environment snapshot");
  const targets = [];
  for (let i = 0; i < targetCount; i++) {
    const offset = targetOffset + i * 56;
    targets.push({ id: text(offset), runtime: text(offset + 8), container: text(offset + 16),
      name: text(offset + 24), state: text(offset + 32), image: text(offset + 40), user: text(offset + 48) });
  }
  const processes = [];
  for (let i = 0; i < processCount; i++) {
    const offset = processOffset + i * 112, target = u32(offset + 96), flags = u32(offset + 44);
    const cpu = view.getFloat64(offset + 48, true);
    if (target >= targets.length || u32(offset + 12) || (flags !== 1 && flags !== 2) ||
        !Number.isFinite(cpu) || cpu < 0 || !u32(offset)) throw new Error("Invalid environment process record");
    const process = { pid: u32(offset), parentPID: u32(offset + 4), containerPID: u32(offset + 8),
      memory: u64(offset + 16), ticks: u64(offset + 32), threads: u32(offset + 40),
      start: text(offset + 56), command: text(offset + 64), user: text(offset + 72), state: text(offset + 80),
      target: targets[target].id, hostPID: u32(offset + 100), hostUser: text(offset + 104) };
    text(offset + 88);
    if (flags === 1) process.cpuTicks = u64(offset + 24);
    else process.cpu = cpu;
    processes.push(process);
  }
  const errors = [];
  for (let i = 0; i < errorCount; i++) {
    const offset = errorOffset + i * 16;
    errors.push({ runtime: text(offset), error: text(offset + 8) });
  }
  return { targets, processes, errors, time: u64(56) / 1000, ticks: u32(64) };
}

(() => {
  "use strict";

  let processes = new Map();
  let updatedAt = 0;
  let timer;
  let controller;
  let stopped = false;

  function lookup(pid) {
    if (Date.now() - updatedAt > 15000) return null;
    return processes.get(pid) || null;
  }

  async function refresh() {
    if (stopped) return;
    if (!document.hidden) {
      controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 10000);
      try {
        const response = await fetch("/api/environments?operation=processes", {
          cache: "no-store", signal: controller.signal
        });
        if (!response.ok) throw new Error(`Environment discovery failed (${response.status})`);
        const result = decodeEnvironmentSnapshot(await response.arrayBuffer());
        const names = new Map(result.targets.map(target => [target.id, target.name]));
        processes = new Map(result.processes
          .filter(process => process.target !== "host" && process.hostPID)
          .map(process => [process.hostPID, { ...process, environment: names.get(process.target) || process.target }]));
        updatedAt = Date.now();
      } catch (error) {
        processes.clear();
      } finally {
        clearTimeout(timeout);
        window.dispatchEvent(new Event("top-environments-changed"));
      }
    }
    if (!stopped) timer = setTimeout(refresh, 5000);
  }

  window.topEnvironments = { lookup };
  window.addEventListener("pagehide", () => {
    stopped = true;
    clearTimeout(timer);
    controller?.abort();
  });
  window.addEventListener("pageshow", event => {
    if (event.persisted) { stopped = false; refresh(); }
  });
  refresh();
})();

function topBinaryReader(buffer, magic, minimum) {
  if (!(buffer instanceof ArrayBuffer) || buffer.byteLength < minimum || buffer.byteLength > 512 * 1024) throw new Error("Invalid Top payload size");
  const view = new DataView(buffer), bytes = new Uint8Array(buffer), decoder = new TextDecoder();
  const u32 = offset => view.getUint32(offset, true);
  const u64 = offset => {
    const value = view.getBigUint64(offset, true);
    if (value > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("Invalid Top integer");
    return Number(value);
  };
  const number = offset => {
    const value = view.getFloat64(offset, true);
    if (!Number.isFinite(value) || value < 0) throw new Error("Invalid Top number");
    return value;
  };
  const text = (field, variable) => {
    const offset = u32(field), length = u32(field + 4);
    if (offset < variable || offset > bytes.length || length > bytes.length - offset) throw new Error("Invalid Top string reference");
    const value = bytes.subarray(offset, offset + length);
    if (value.includes(0)) throw new Error("Invalid Top string");
    return decoder.decode(value);
  };
  if (decoder.decode(bytes.subarray(0, 4)) !== magic || u32(4) !== 1 || u32(8) !== bytes.length) throw new Error("Invalid Top header");
  return { u32, u64, number, text };
}

function decodeTopCPUHistory(buffer) {
  const r = topBinaryReader(buffer, "OTCH", 32), count = r.u32(12);
  if (r.u32(16) !== 40 || r.u32(20) !== 32 || r.u64(24) !== 0 || buffer.byteLength !== 32 + count * 40) throw new Error("Invalid Top history records");
  const samples = [];
  for (let i = 0; i < count; i++) {
    const offset = 32 + i * 40, flags = r.u32(offset + 8);
    if (flags > 1 || r.u32(offset + 12)) throw new Error("Invalid Top history flags");
    samples.push({timestamp: r.number(offset), hasCPU: flags === 1, userPercent: r.number(offset + 16), systemPercent: r.number(offset + 24), idlePercent: r.number(offset + 32)});
  }
  return { samples };
}

function decodeTopProcessDetail(buffer) {
  const r = topBinaryReader(buffer, "OTPD", 144), count = r.u32(12), variable = r.u32(24), flags = r.u32(28);
  if (r.u32(16) !== 24 || r.u32(20) !== 144 || variable !== 144 + count * 24 || variable > buffer.byteLength ||
      flags > 1 || r.u32(84) || r.u64(136) || !r.u32(40)) throw new Error("Invalid Top detail records");
  const process = {pid: r.u32(40), parentPID: r.u32(44), cpuPercent: r.number(48), memoryKilobytes: r.u64(56),
    virtualMemoryKilobytes: r.u64(64), cpuTimeMilliseconds: r.u64(72), threadCount: r.u32(80) || null,
    isKernelThread: flags === 1, user: r.text(88, variable), command: r.text(96, variable),
    shortCommand: r.text(104, variable), parentShortCommand: r.text(112, variable) || null,
    launchTime: r.text(120, variable) || null, openFilesError: r.text(128, variable) || null, openFiles: []};
  process.commandLine = process.command;
  for (let i = 0; i < count; i++) {
    const offset = 144 + i * 24;
    process.openFiles.push({descriptor: r.text(offset, variable), type: r.text(offset + 8, variable), name: r.text(offset + 16, variable)});
  }
  return {timestamp: r.number(32), process};
}
