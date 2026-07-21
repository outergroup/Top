(() => {
  "use strict";

  const ROW_HEIGHT = 28;
  const TABLE_HEADER_HEIGHT = 28;
  const OVERSCAN_ROWS = 5;
  const CHART_DURATION = 180;
  const MAX_CHART_BARS = 180;
  const MAX_FRAME_ROWS = 10000;
  const ROW_MOVE_MS = 250;
  const decoder = new TextDecoder();
  const $ = selector => document.querySelector(selector);

  const elements = {
    connection: $("#connection"), connectionLabel: $("#connection-label"),
    viewport: $("#process-viewport"),
    spacer: $("#row-spacer"), rowStripes: $("#row-stripes"),
    rows: $("#rows"), empty: $("#empty-state"),
    search: $("#search"), stop: $("#stop-button"), inspect: $("#inspect-button"),
    cpuIdle: $("#cpu-idle"), cpuUser: $("#cpu-user"), cpuSystem: $("#cpu-system"),
    processCount: $("#process-count"), threadCount: $("#thread-count"),
    chart: $("#cpu-chart"), chartBars: $("#chart-bars"), chartHitTarget: $("#chart-hit-target"),
    chartMax: $("#chart-max"), chartHalf: $("#chart-half"),
    dimLeft: $("#selection-dim-left"), dimRight: $("#selection-dim-right"), selectionRange: $("#selection-range"),
    hoverLine: $("#chart-hover-line"), chartTooltip: $("#chart-tooltip"), selectionTooltip: $("#selection-tooltip"),
    drawer: $("#detail-drawer"), drawerScrim: $("#drawer-scrim"), closeDrawer: $("#close-drawer"),
    detailTitle: $("#detail-title"), detailBody: $("#detail-body"),
    stopDialog: $("#stop-dialog"), stopMessage: $("#stop-message")
  };

  const state = {
    clientId: crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`,
    total: 0, sort: "cpu", ascending: false, search: "", selectedPID: null, selectedName: "",
    pendingSelectionIndex: null,
    selection: { mode: "trailing", duration: 60 }, historical: false,
    snapshotIndex: 0, requestedStart: -1, requestedEnd: -1,
    rowViews: new Map(), streamController: null, viewportController: null, historyController: null, detailController: null,
    reconnectTimer: 0, reconnectAttempt: 0, viewportTimer: 0, viewportRequestAt: 0,
    scrollTimer: 0, searchTimer: 0, historyTimer: 0, historyRequestAt: 0,
    cpuHistory: [], liveMetrics: null, displayMetrics: null, atlasRevision: 0
  };

  function cssColor(name) {
    return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  }

  const numericFont = '400 13px -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif';

  function makeAtlas(tokens, widthMode, normalColor = cssColor("--text")) {
    const logicalHeight = 18;
    const horizontalPadding = 2;
    const scale = Math.max(2, Math.min(3, window.devicePixelRatio || 1));
    const measuringCanvas = document.createElement("canvas");
    const measuringContext = measuringCanvas.getContext("2d");
    measuringContext.font = numericFont;
    const measuredWidths = tokens.map(token => Math.ceil(measuringContext.measureText(token).width));
    const tabularWidth = Math.max(...measuredWidths);
    const logicalWidths = measuredWidths.map(width => widthMode === "tabular" ? tabularWidth : width);
    const cellWidths = logicalWidths.map(width => width + horizontalPadding * 2);
    const offsets = [];
    let sheetWidth = 0;
    cellWidths.forEach(width => { offsets.push(sheetWidth); sheetWidth += width; });
    const canvas = document.createElement("canvas");
    canvas.width = Math.ceil(sheetWidth * scale);
    canvas.height = Math.ceil(logicalHeight * 2 * scale);
    const context = canvas.getContext("2d", { alpha: true });
    context.scale(scale, scale);
    context.textAlign = "center";
    context.textBaseline = "middle";
    context.font = numericFont;
    const colors = [normalColor, "#ffffff"];
    colors.forEach((color, row) => {
      context.fillStyle = color;
      tokens.forEach((token, column) => {
        context.fillText(token, offsets[column] + cellWidths[column] / 2, row * logicalHeight + logicalHeight / 2 + .25);
      });
    });
    return {
      tokens, logicalWidths, logicalHeight, cellWidths, offsets, horizontalPadding, sheetWidth,
      sheetHeight: logicalHeight * colors.length, url: `url(${JSON.stringify(canvas.toDataURL("image/png"))})`
    };
  }

  let atlases = {};
  function buildAtlases() {
    const digitTokens = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"];
    const punctuationTokens = [".", ":", "%", "-", "–", "/"];
    atlases = {
      digits: makeAtlas(digitTokens, "tabular"),
      punctuation: makeAtlas(punctuationTokens, "natural"),
      units: makeAtlas(["KB", "MB", "GB"], "natural"),
      placeholder: makeAtlas(["—"], "natural"),
      userDigits: makeAtlas(digitTokens, "tabular", cssColor("--user")),
      userPunctuation: makeAtlas(punctuationTokens, "natural", cssColor("--user")),
      userPlaceholder: makeAtlas(["—"], "natural", cssColor("--user")),
      systemDigits: makeAtlas(digitTokens, "tabular", cssColor("--system")),
      systemPunctuation: makeAtlas(punctuationTokens, "natural", cssColor("--system")),
      systemPlaceholder: makeAtlas(["—"], "natural", cssColor("--system"))
    };
    const pidDigitCount = 6;
    const cellHorizontalInsets = 16;
    document.documentElement.style.setProperty(
      "--pid-column-min-width",
      `${atlases.digits.logicalWidths[0] * pidDigitCount + cellHorizontalInsets}px`
    );
    state.atlasRevision += 1;
  }

  function atlasToken(token, palette) {
    const prefix = palette === "user" ? "user" : palette === "system" ? "system" : "";
    const digitAtlas = prefix ? atlases[`${prefix}Digits`] : atlases.digits;
    const punctuationAtlas = prefix ? atlases[`${prefix}Punctuation`] : atlases.punctuation;
    const placeholderAtlas = prefix ? atlases[`${prefix}Placeholder`] : atlases.placeholder;
    if (/^[0-9]$/.test(token)) return [digitAtlas, Number(token), ""];
    const punctuation = punctuationAtlas.tokens.indexOf(token);
    if (punctuation >= 0) return [punctuationAtlas, punctuation, ""];
    const unit = atlases.units.tokens.indexOf(token);
    if (unit >= 0) return [atlases.units, unit, " unit"];
    return [placeholderAtlas, 0, ""];
  }

  function tokenize(value) {
    const tokens = [];
    const text = String(value);
    for (let index = 0; index < text.length;) {
      const possibleUnit = text.slice(index, index + 2);
      if (possibleUnit === "KB" || possibleUnit === "MB" || possibleUnit === "GB") {
        tokens.push(possibleUnit); index += 2;
      } else if (text[index] === " ") {
        index += 1;
      } else {
        tokens.push(text[index]); index += 1;
      }
    }
    return tokens;
  }

  class SpriteText {
    constructor(host, slotCount, palette = "normal") {
      this.host = host;
      this.palette = palette;
      this.host.classList.add("sprite-text");
      this.host.replaceChildren();
      this.slots = [];
      this.keys = new Array(slotCount).fill("");
      for (let index = 0; index < slotCount; index += 1) {
        const slot = document.createElement("i");
        slot.className = "sprite-glyph blank";
        slot.setAttribute("aria-hidden", "true");
        this.host.append(slot); this.slots.push(slot);
      }
    }

    set(value, selected = false) {
      const rawTokens = tokenize(value);
      const tokens = rawTokens.slice(-this.slots.length);
      while (tokens.length < this.slots.length) tokens.unshift("");
      const row = selected ? 1 : 0;
      this.host.setAttribute("aria-label", String(value));
      for (let index = 0; index < this.slots.length; index += 1) {
        const token = tokens[index];
        const key = `${state.atlasRevision}:${this.palette}:${row}:${token}`;
        if (this.keys[index] === key) continue;
        this.keys[index] = key;
        const slot = this.slots[index];
        if (!token) {
          slot.className = "sprite-glyph blank";
          slot.style.width = `${atlases.digits.logicalWidths[0]}px`;
          continue;
        }
        const [atlas, atlasIndex, extraClass] = atlasToken(token, this.palette);
        slot.className = `sprite-glyph${extraClass}`;
        slot.style.width = `${atlas.logicalWidths[atlasIndex]}px`;
        slot.style.backgroundImage = atlas.url;
        slot.style.backgroundSize = `${atlas.sheetWidth}px ${atlas.sheetHeight}px`;
        slot.style.backgroundPosition = `${-(atlas.offsets[atlasIndex] + atlas.horizontalPadding)}px ${-row * atlas.logicalHeight}px`;
      }
    }

    invalidate() { this.keys.fill(""); }
  }

  buildAtlases();
  const metricSprites = {
    idle: new SpriteText(elements.cpuIdle, 8), user: new SpriteText(elements.cpuUser, 8, "user"), system: new SpriteText(elements.cpuSystem, 8, "system"),
    processes: new SpriteText(elements.processCount, 10), threads: new SpriteText(elements.threadCount, 10)
  };

  function appendTextCell(row, className) {
    const cell = document.createElement("span");
    cell.className = `process-cell text-cell ${className}`;
    cell.setAttribute("role", "cell"); row.append(cell); return cell;
  }

  function appendNumberCell(row, slotCount) {
    const cell = document.createElement("span");
    cell.className = "process-cell number-cell"; cell.setAttribute("role", "cell");
    row.append(cell); return new SpriteText(cell, slotCount);
  }

  class ProcessRowView {
    constructor(process, index, animate) {
      this.pid = process.pid; this.index = index; this.process = process; this.transient = false;
      this.element = document.createElement("div");
      this.element.className = "process-row process-grid";
      this.element.dataset.pid = String(process.pid);
      this.element.setAttribute("role", "row");
      this.commandCell = appendTextCell(this.element, "command");
      this.userCell = appendTextCell(this.element, "user");
      this.cpuSprite = appendNumberCell(this.element, 7);
      this.cpuTimeSprite = appendNumberCell(this.element, 14);
      this.memorySprite = appendNumberCell(this.element, 8);
      this.pidSprite = appendNumberCell(this.element, 6);
      this.command = ""; this.user = "";
      elements.rows.append(this.element);
      this.update(process, index);
      this.move(index, process.previousIndex, animate, true);
    }

    update(process, index) {
      this.process = process; this.index = index;
      const selected = process.pid === state.selectedPID;
      this.element.dataset.pid = String(process.pid);
      this.element.dataset.name = process.command || "";
      this.element.setAttribute("aria-rowindex", String(index + 1));
      this.element.classList.toggle("selected", selected);
      this.element.setAttribute("aria-selected", String(selected));
      this.element.classList.toggle("kernel-row", process.kernel);
      if (this.command !== process.command) {
        this.command = process.command; this.commandCell.textContent = process.command || `PID ${process.pid}`;
        this.commandCell.title = this.commandCell.textContent;
      }
      if (this.user !== process.user) {
        this.user = process.user; this.userCell.textContent = process.user || "—"; this.userCell.title = this.userCell.textContent;
      }
      this.commandCell.classList.toggle("kernel", process.kernel);
      this.userCell.classList.toggle("kernel", process.kernel);
      this.cpuSprite.set(formatDecimal(process.cpu, 1), selected);
      this.cpuTimeSprite.set(formatCPUTime(process.cpuTimeMS), selected);
      this.memorySprite.set(process.kernel ? "—" : formatMemory(process.memoryKB), selected);
      this.pidSprite.set(String(process.pid), selected);
    }

    move(index, previousIndex, animate, isNew = false) {
      this.index = index;
      this.element.style.setProperty("--row-y", `${index * ROW_HEIGHT}px`);
      if (isNew && animate && previousIndex !== null && previousIndex !== index) {
        this.element.style.setProperty("--previous-row-y", `${previousIndex * ROW_HEIGHT}px`);
        this.element.classList.add("from-previous");
        this.element.addEventListener("animationend", () => this.element.classList.remove("from-previous"), { once: true });
      }
    }

    invalidateSprites() {
      [this.cpuSprite, this.cpuTimeSprite, this.memorySprite, this.pidSprite].forEach(sprite => sprite.invalidate());
      this.update(this.process, this.index);
    }

    removeAfterAnimation() {
      if (this.transient) return;
      this.transient = true; this.element.classList.add("departing");
      window.setTimeout(() => {
        if (!this.transient) return;
        this.element.remove();
        if (state.rowViews.get(this.pid) === this) state.rowViews.delete(this.pid);
      }, ROW_MOVE_MS + 80);
    }

    removeNow() { this.element.remove(); if (state.rowViews.get(this.pid) === this) state.rowViews.delete(this.pid); }
  }

  function setConnection(kind, label) {
    elements.connection.className = `connection-status ${kind || ""}`;
    elements.connectionLabel.textContent = label;
  }

  function selectionQuery(selection = state.selection) {
    if (selection.mode === "fixed") {
      return { timeMode: "fixed", timeStart: selection.start.toFixed(3), timeEnd: selection.end.toFixed(3) };
    }
    return { timeMode: "trailing", timeDuration: Math.max(.5, selection.duration).toFixed(3) };
  }

  function queryForViewport(start, end, includeClient = true, selection = state.selection) {
    const query = new URLSearchParams({
      start: String(start), end: String(end), search: state.search, sort: state.sort,
      direction: state.ascending ? "asc" : "desc", ...selectionQuery(selection)
    });
    if (includeClient) {
      query.set("clientId", state.clientId);
      query.set("snapshot", String(state.snapshotIndex));
      query.set("immediate", "1");
    }
    return query;
  }

  function visibleRange() {
    const visibleCount = Math.max(1, Math.ceil(processRowsViewportHeight() / ROW_HEIGHT));
    const firstVisible = Math.max(0, Math.floor(elements.viewport.scrollTop / ROW_HEIGHT));
    const start = Math.max(0, firstVisible - OVERSCAN_ROWS);
    const upperLimit = state.total || Number.MAX_SAFE_INTEGER;
    const end = Math.max(start + 1, Math.min(upperLimit, firstVisible + visibleCount + OVERSCAN_ROWS));
    return { start, end };
  }

  function scheduleViewport(immediate = false, force = false, throttle = false) {
    clearTimeout(state.viewportTimer);
    const update = () => {
      state.viewportTimer = 0;
      const range = visibleRange();
      if (!force && range.start === state.requestedStart && range.end === state.requestedEnd) return;
      state.requestedStart = range.start; state.requestedEnd = range.end;
      if (state.historical) scheduleHistoricalRequest(true);
      else requestViewport(range.start, range.end);
    };
    if (immediate) update();
    else if (throttle) {
      const delay = Math.max(0, 35 - (performance.now() - state.viewportRequestAt));
      if (delay === 0) update(); else state.viewportTimer = window.setTimeout(update, delay);
    } else state.viewportTimer = window.setTimeout(update, 24);
  }

  async function requestViewport(start, end) {
    if (!state.streamController || state.historical) return;
    state.viewportRequestAt = performance.now();
    state.viewportController?.abort();
    const controller = new AbortController(); state.viewportController = controller;
    try {
      const response = await fetch(`/api/processes/viewport?${queryForViewport(start, end)}`, { cache: "no-store", signal: controller.signal });
      if (!response.ok && response.status !== 404) throw new Error(`Viewport request failed (${response.status})`);
    } catch (error) {
      if (error.name !== "AbortError") console.warn(error);
    } finally {
      if (state.viewportController === controller) state.viewportController = null;
    }
  }

  function readU64(view, offset) {
    return view.getUint32(offset, true) + view.getUint32(offset + 4, true) * 4294967296;
  }

  function parseEntry(bytes, view, offset) {
    const fixedSize = 37;
    if (bytes.byteLength < offset + fixedSize) return null;
    const userLength = view.getUint32(offset + 24, true);
    const commandLength = view.getUint32(offset + 28, true);
    if (userLength > 65536 || commandLength > 65536) throw new Error("Invalid process stream entry");
    const end = offset + fixedSize + userLength + commandLength;
    if (bytes.byteLength < end) return null;
    const userStart = offset + fixedSize;
    const previousIndex = view.getInt32(offset + 32, true);
    return {
      value: {
        pid: view.getUint32(offset, true), cpu: view.getFloat32(offset + 4, true),
        memoryKB: readU64(view, offset + 8), cpuTimeMS: readU64(view, offset + 16),
        previousIndex: previousIndex >= 0 ? previousIndex : null, kernel: (view.getUint8(offset + 36) & 1) !== 0,
        user: decoder.decode(bytes.subarray(userStart, userStart + userLength)),
        command: decoder.decode(bytes.subarray(userStart + userLength, end))
      }, offset: end
    };
  }

  function parseFrame(bytes) {
    const headerSize = 52;
    if (bytes.byteLength < headerSize) return null;
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const count = view.getUint32(8, true), total = view.getUint32(16, true);
    if (count > MAX_FRAME_ROWS || total > 10000000) throw new Error("Invalid process stream frame");
    const flags = view.getUint8(44);
    const frame = {
      timestamp: view.getFloat64(0, true), count, windowStart: view.getUint32(12, true), total,
      snapshotIndex: readU64(view, 20), selectionStart: view.getFloat64(28, true), selectionEnd: view.getFloat64(36, true),
      hasSelection: (flags & 1) !== 0, trailingSelection: (flags & 2) !== 0,
      entries: [], additional: [], metrics: null
    };
    let offset = headerSize;
    for (let index = 0; index < count; index += 1) {
      const parsed = parseEntry(bytes, view, offset); if (!parsed) return null;
      frame.entries.push(parsed.value); offset = parsed.offset;
    }
    const metricsSize = 29;
    if (bytes.byteLength < offset + metricsSize) return null;
    frame.metrics = {
      hasCPU: view.getUint8(offset) !== 0, user: view.getFloat32(offset + 1, true),
      system: view.getFloat32(offset + 5, true), idle: view.getFloat32(offset + 9, true),
      processCount: view.getUint32(offset + 13, true), visibleProcessCount: view.getUint32(offset + 17, true),
      threadCount: view.getUint32(offset + 21, true), logicalCPUCount: view.getUint32(offset + 25, true)
    };
    offset += metricsSize;
    if (bytes.byteLength < offset + 4) return null;
    const additionalCount = view.getUint32(offset, true); offset += 4;
    if (additionalCount > MAX_FRAME_ROWS) throw new Error("Invalid additional process count");
    for (let index = 0; index < additionalCount; index += 1) {
      if (bytes.byteLength < offset + 4) return null;
      const rowIndex = view.getUint32(offset, true); offset += 4;
      const parsed = parseEntry(bytes, view, offset); if (!parsed) return null;
      frame.additional.push([rowIndex, parsed.value]); offset = parsed.offset;
    }
    return { frame, consumed: offset };
  }

  function concatenate(left, right) {
    if (!left.byteLength) return right;
    const combined = new Uint8Array(left.byteLength + right.byteLength);
    combined.set(left); combined.set(right, left.byteLength); return combined;
  }

  function applyTableFrame(frame) {
    const animate = state.snapshotIndex !== 0 && frame.snapshotIndex !== state.snapshotIndex;
    state.snapshotIndex = frame.snapshotIndex;
    const seen = new Set();

    const upsert = (index, process, transient) => {
      seen.add(process.pid);
      let view = state.rowViews.get(process.pid);
      if (!view) {
        view = new ProcessRowView(process, index, animate);
        state.rowViews.set(process.pid, view);
      } else {
        view.transient = false; view.element.classList.remove("departing");
        view.update(process, index); view.move(index, process.previousIndex, animate, false);
      }
      if (transient) view.removeAfterAnimation();
    };

    frame.entries.forEach((process, offset) => upsert(frame.windowStart + offset, process, false));
    frame.additional.forEach(([index, process]) => { if (!seen.has(process.pid)) upsert(index, process, true); });

    for (const view of [...state.rowViews.values()]) {
      if (!seen.has(view.pid) && !view.transient) view.removeNow();
    }

    state.total = frame.total;
    if (state.pendingSelectionIndex !== null) {
      state.pendingSelectionIndex = frame.total ? Math.min(state.pendingSelectionIndex, frame.total - 1) : null;
    }
    elements.viewport.setAttribute("aria-rowcount", String(frame.total));
    elements.spacer.style.height = `${Math.max(frame.total * ROW_HEIGHT, processRowsViewportHeight())}px`;
    elements.rowStripes.style.height = `${frame.total * ROW_HEIGHT}px`;
    elements.empty.hidden = frame.total !== 0;
    resolvePendingSelection();
  }

  function applyLiveFrame(frame) {
    state.liveMetrics = frame.metrics;
    if (!state.historical) state.displayMetrics = frame.metrics;
    addCPUHistorySample(frame);
    updateMetrics(); chart.render();
    if (!state.historical) applyTableFrame(frame);
  }

  function applyHistoricalFrame(frame) {
    if (!state.historical) return;
    state.displayMetrics = frame.metrics;
    applyTableFrame(frame); updateMetrics();
    setConnection("", "Viewing historical data");
  }

  async function loadCPUHistory() {
    try {
      const response = await fetch("/api/processes/cpu_history", { cache: "no-store" });
      if (!response.ok) return;
      const payload = await response.json();
      state.cpuHistory = (payload.samples || []).filter(sample => sample.hasCPU).map(sample => ({
        timestamp: sample.timestamp, user: sample.userPercent, system: sample.systemPercent, idle: sample.idlePercent
      }));
      trimCPUHistory(); updateMetrics(); chart.render();
    } catch (_) { /* The live stream will populate the chart. */ }
  }

  async function connectStream() {
    clearTimeout(state.reconnectTimer); state.streamController?.abort();
    const controller = new AbortController(); state.streamController = controller;
    const range = visibleRange(); state.requestedStart = range.start; state.requestedEnd = range.end;
    setConnection("", "Connecting…");
    try {
      const response = await fetch(`/api/processes/stream?${queryForViewport(range.start, range.end)}`, {
        cache: "no-store", headers: { Accept: "application/octet-stream" }, signal: controller.signal
      });
      if (!response.ok || !response.body) throw new Error(`Stream unavailable (${response.status})`);
      setConnection("live", "Live"); state.reconnectAttempt = 0;
      const reader = response.body.getReader(); let buffer = new Uint8Array(0);
      while (true) {
        const result = await reader.read(); if (result.done) break;
        buffer = concatenate(buffer, result.value);
        while (buffer.byteLength) {
          const parsed = parseFrame(buffer); if (!parsed) break;
          applyLiveFrame(parsed.frame); buffer = buffer.subarray(parsed.consumed);
        }
      }
      throw new Error("Stream ended");
    } catch (error) {
      if (controller.signal.aborted || state.streamController !== controller) return;
      setConnection("error", "Connection lost — reconnecting…"); console.warn("Top stream disconnected", error);
      const delay = Math.min(1000 * 2 ** state.reconnectAttempt, 15000); state.reconnectAttempt += 1;
      state.reconnectTimer = window.setTimeout(connectStream, delay);
    }
  }

  function scheduleHistoricalRequest(immediate = false) {
    clearTimeout(state.historyTimer);
    if (!state.historical || state.selection.mode !== "fixed") return;
    const delay = immediate ? 0 : Math.max(0, 35 - (performance.now() - state.historyRequestAt));
    if (delay === 0) requestHistoricalSnapshot();
    else state.historyTimer = window.setTimeout(requestHistoricalSnapshot, delay);
  }

  async function requestHistoricalSnapshot() {
    if (!state.historical || state.selection.mode !== "fixed") return;
    state.historyRequestAt = performance.now();
    const range = visibleRange(); state.requestedStart = range.start; state.requestedEnd = range.end;
    state.historyController?.abort();
    const controller = new AbortController(); state.historyController = controller;
    setConnection("", "Loading historical data…");
    try {
      const response = await fetch(`/api/processes/history?${queryForViewport(range.start, range.end, false)}`, {
        cache: "no-store", headers: { Accept: "application/octet-stream" }, signal: controller.signal
      });
      if (!response.ok) throw new Error(`History request failed (${response.status})`);
      const parsed = parseFrame(new Uint8Array(await response.arrayBuffer()));
      if (!parsed) throw new Error("Incomplete history response");
      if (state.historyController === controller) applyHistoricalFrame(parsed.frame);
    } catch (error) {
      if (error.name !== "AbortError") { setConnection("error", "Historical data unavailable"); console.warn(error); }
    } finally {
      if (state.historyController === controller) state.historyController = null;
    }
  }

  function addCPUHistorySample(frame) {
    if (!frame.metrics?.hasCPU) return;
    const last = state.cpuHistory.at(-1);
    if (!last || Math.abs(last.timestamp - frame.timestamp) >= .001) {
      state.cpuHistory.push({ timestamp: frame.timestamp, user: frame.metrics.user, system: frame.metrics.system, idle: frame.metrics.idle });
      trimCPUHistory();
    }
  }

  function trimCPUHistory() {
    const newest = state.cpuHistory.at(-1)?.timestamp || Date.now() / 1000;
    const first = state.cpuHistory.findIndex(sample => sample.timestamp >= newest - CHART_DURATION);
    if (first > 0) state.cpuHistory.splice(0, first);
  }

  function latestHistoryTime() { return state.cpuHistory.at(-1)?.timestamp || Date.now() / 1000; }

  function selectedTimeRange() {
    const latest = latestHistoryTime();
    if (state.selection.mode === "fixed") return [state.selection.start, state.selection.end];
    return [latest - state.selection.duration, latest];
  }

  function updateMetrics() {
    const metrics = state.displayMetrics || state.liveMetrics;
    const [start, end] = selectedTimeRange();
    const samples = state.cpuHistory.filter(sample => sample.timestamp >= start && sample.timestamp <= end);
    let cpu = null;
    if (samples.length) {
      cpu = samples.reduce((sum, sample) => ({ user: sum.user + sample.user, system: sum.system + sample.system, idle: sum.idle + sample.idle }), { user: 0, system: 0, idle: 0 });
      cpu.user /= samples.length; cpu.system /= samples.length; cpu.idle /= samples.length;
    } else if (metrics?.hasCPU) cpu = metrics;
    metricSprites.idle.set(cpu ? `${formatDecimal(cpu.idle, 1)}%` : "—");
    metricSprites.user.set(cpu ? `${formatDecimal(cpu.user, 1)}%` : "—");
    metricSprites.system.set(cpu ? `${formatDecimal(cpu.system, 1)}%` : "—");
    metricSprites.processes.set(metrics?.processCount ? String(metrics.processCount) : "—");
    metricSprites.threads.set(metrics?.threadCount ? String(metrics.threadCount) : "—");
    const cores = Math.max(1, metrics?.logicalCPUCount || state.liveMetrics?.logicalCPUCount || 1);
    elements.chartMax.textContent = `${cores} ${cores === 1 ? "core" : "cores"}`;
    const half = cores / 2;
    elements.chartHalf.textContent = `${Number.isInteger(half) ? half : half.toFixed(1)} ${half === 1 ? "core" : "cores"}`;
  }

  class CPUHistoryChart {
    constructor() {
      this.bars = [];
      this.drag = null;
      this.selectionAnimationTimer = 0;
      for (let index = 0; index < MAX_CHART_BARS; index += 1) {
        const bar = document.createElement("i"); bar.className = "chart-bar";
        const system = document.createElement("i"); system.className = "system";
        const user = document.createElement("i"); user.className = "user";
        bar.append(system, user); elements.chartBars.append(bar);
        this.bars.push({ bar, user, system, key: "" });
      }
      elements.chartHitTarget.addEventListener("pointerdown", event => this.pointerDown(event));
      elements.chartHitTarget.addEventListener("pointermove", event => this.pointerMove(event));
      elements.chartHitTarget.addEventListener("pointerup", event => this.pointerUp(event));
      elements.chartHitTarget.addEventListener("pointercancel", event => this.pointerUp(event));
      elements.chartHitTarget.addEventListener("pointerleave", () => {
        if (!this.drag) { this.hideHover(); this.setResizeCursor(false); }
      });
      elements.chartHitTarget.addEventListener("dblclick", event => {
        event.preventDefault(); setSelection({ mode: "trailing", duration: 60 }, false, true);
      });
      $("#chart-ticks").addEventListener("click", event => {
        const tick = event.target.closest("[data-ago]"); if (!tick) return;
        setSelection({ mode: "trailing", duration: Math.max(1, Number(tick.dataset.ago)) }, false, true);
      });
    }

    render() {
      const latest = latestHistoryTime(), earliest = latest - CHART_DURATION;
      const metrics = state.liveMetrics || state.displayMetrics;
      const cores = Math.max(1, metrics?.logicalCPUCount || 1), scale = cores * 100;
      const samples = state.cpuHistory.filter(sample => sample.timestamp >= earliest).slice(-MAX_CHART_BARS);
      for (let index = 0; index < this.bars.length; index += 1) {
        const view = this.bars[index], sample = samples[index];
        if (!sample) { if (view.key !== "hidden") { view.bar.hidden = true; view.key = "hidden"; } continue; }
        const next = samples[index + 1];
        const left = Math.max(0, Math.min(1, (sample.timestamp - earliest) / CHART_DURATION));
        const secondsWide = Math.max(.7, Math.min(3, next ? next.timestamp - sample.timestamp : 1));
        const width = secondsWide / CHART_DURATION;
        const userHeight = Math.max(0, Math.min(100, sample.user / scale * 100));
        const totalHeight = Math.max(userHeight, Math.min(100, (sample.user + sample.system) / scale * 100));
        const key = `${left.toFixed(5)}:${width.toFixed(5)}:${userHeight.toFixed(3)}:${totalHeight.toFixed(3)}`;
        if (view.key !== key) {
          view.bar.hidden = false; view.bar.style.left = `${left * 100}%`; view.bar.style.width = `${width * 100}%`;
          view.user.style.height = `${userHeight}%`; view.system.style.height = `${totalHeight}%`; view.key = key;
        }
      }
      this.updateSelectionOverlay();
    }

    updateSelectionOverlay(animate) {
      if (animate === true) {
        clearTimeout(this.selectionAnimationTimer);
        elements.chart.classList.add("animate-selection");
        this.selectionAnimationTimer = window.setTimeout(() => {
          elements.chart.classList.remove("animate-selection");
          this.selectionAnimationTimer = 0;
        }, ROW_MOVE_MS + 40);
      } else if (animate === false) {
        clearTimeout(this.selectionAnimationTimer); this.selectionAnimationTimer = 0;
        elements.chart.classList.remove("animate-selection");
      }
      const latest = latestHistoryTime(), earliest = latest - CHART_DURATION;
      const [selectionStart, selectionEnd] = selectedTimeRange();
      const start = Math.max(0, Math.min(1, (selectionStart - earliest) / CHART_DURATION));
      const end = Math.max(start, Math.min(1, (selectionEnd - earliest) / CHART_DURATION));
      elements.dimLeft.style.left = "0"; elements.dimLeft.style.width = `${start * 100}%`;
      elements.dimRight.style.left = `${end * 100}%`; elements.dimRight.style.right = "0";
      elements.selectionRange.style.left = `${start * 100}%`;
      elements.selectionRange.style.width = `${Math.max(.25, (end - start) * 100)}%`;
    }

    chartX(event) {
      const rect = elements.chartHitTarget.getBoundingClientRect();
      return Math.max(0, Math.min(rect.width, event.clientX - rect.left));
    }

    timeForX(x) {
      const width = Math.max(1, elements.chartHitTarget.clientWidth);
      return latestHistoryTime() - CHART_DURATION + x / width * CHART_DURATION;
    }

    xForTime(time) {
      return (time - (latestHistoryTime() - CHART_DURATION)) / CHART_DURATION * elements.chartHitTarget.clientWidth;
    }

    pointerDown(event) {
      if (event.button !== undefined && event.button !== 0) return;
      event.preventDefault(); elements.chartHitTarget.setPointerCapture(event.pointerId);
      const x = this.chartX(event), [start, end] = selectedTimeRange();
      const startX = this.xForTime(start), endX = this.xForTime(end), slop = 11;
      let anchor, anchorIsNow = false, onHandle = false;
      if (Math.abs(x - startX) <= slop) {
        anchor = end; anchorIsNow = state.selection.mode === "trailing"; onHandle = true;
      } else if (Math.abs(x - endX) <= slop) {
        anchor = start; onHandle = true;
      } else anchor = this.timeForX(x);
      this.drag = { pointerId: event.pointerId, anchor, anchorIsNow };
      this.applyDrag(x, false, !onHandle);
    }

    pointerMove(event) {
      const x = this.chartX(event);
      if (this.drag && this.drag.pointerId === event.pointerId) { event.preventDefault(); this.applyDrag(x); }
      else { this.setResizeCursor(this.isNearHandle(x)); this.showHover(x); }
    }

    pointerUp(event) {
      if (!this.drag || this.drag.pointerId !== event.pointerId) return;
      this.applyDrag(this.chartX(event), true); this.drag = null;
      elements.selectionTooltip.hidden = true;
      try { elements.chartHitTarget.releasePointerCapture(event.pointerId); } catch (_) { /* already released */ }
      this.setResizeCursor(this.isNearHandle(this.chartX(event)));
    }

    applyDrag(x, immediate = false, animate = false) {
      const latest = latestHistoryTime();
      let moving = this.timeForX(x);
      if (latest - moving <= .5) moving = latest;
      const anchor = this.drag.anchorIsNow ? latest : this.drag.anchor;
      const lower = Math.min(anchor, moving), upper = Math.max(anchor, moving);
      const duration = Math.max(.5, upper - lower);
      const selection = upper === latest ? { mode: "trailing", duration } : { mode: "fixed", start: lower, end: Math.max(lower + .5, upper) };
      setSelection(selection, immediate, animate);
      elements.selectionTooltip.textContent = formatDuration(duration);
      elements.selectionTooltip.style.left = `${(this.xForTime(lower) + this.xForTime(upper)) / 2}px`;
      elements.selectionTooltip.hidden = false;
    }

    isNearHandle(x) {
      const [start, end] = selectedTimeRange();
      return Math.abs(x - this.xForTime(start)) <= 7 || Math.abs(x - this.xForTime(end)) <= 7;
    }

    setResizeCursor(active) {
      elements.chartHitTarget.classList.toggle("resize-cursor", active);
    }

    showHover(x) {
      if (!state.cpuHistory.length) return;
      const time = this.timeForX(x);
      let closest = state.cpuHistory[0], distance = Math.abs(closest.timestamp - time);
      for (const sample of state.cpuHistory) {
        const candidate = Math.abs(sample.timestamp - time);
        if (candidate < distance) { closest = sample; distance = candidate; }
      }
      elements.hoverLine.style.left = `${x}px`; elements.hoverLine.hidden = false;
      elements.chartTooltip.textContent = `User ${formatDecimal(closest.user, 1)}%   System ${formatDecimal(closest.system, 1)}%`;
      elements.chartTooltip.style.left = `${x}px`; elements.chartTooltip.style.top = "55%"; elements.chartTooltip.hidden = false;
    }

    hideHover() { elements.hoverLine.hidden = true; elements.chartTooltip.hidden = true; }
  }

  const chart = new CPUHistoryChart();

  function selectionsEqual(left, right) {
    if (left.mode !== right.mode) return false;
    if (left.mode === "trailing") return Math.abs(left.duration - right.duration) < .01;
    return Math.abs(left.start - right.start) + Math.abs(left.end - right.end) < .01;
  }

  function setSelection(selection, immediate = false, animate = false) {
    if (selectionsEqual(selection, state.selection)) {
      if (immediate) {
        if (state.historical) scheduleHistoricalRequest(true);
        else scheduleViewport(true, true, true);
      }
      return;
    }
    const wasHistorical = state.historical;
    state.selection = selection; state.historical = selection.mode === "fixed";
    chart.updateSelectionOverlay(animate); updateMetrics();
    if (state.historical) {
      scheduleHistoricalRequest(immediate);
    } else {
      state.historyController?.abort(); state.historyController = null;
      state.displayMetrics = state.liveMetrics;
      if (wasHistorical) state.snapshotIndex = 0;
      setConnection("live", "Live");
      scheduleViewport(immediate, true, true);
    }
  }

  function formatDecimal(value, digits) { return Number.isFinite(value) ? value.toFixed(digits) : "—"; }

  function formatMemory(kilobytes) {
    if (!Number.isFinite(kilobytes)) return "—";
    if (kilobytes < 1024) return `${Math.round(kilobytes)} KB`;
    if (kilobytes < 1024 * 1024 - 512) return `${(kilobytes / 1024).toFixed(1)} MB`;
    return `${(kilobytes / (1024 * 1024)).toFixed(2)} GB`;
  }

  function formatCPUTime(milliseconds) {
    if (!Number.isFinite(milliseconds)) return "—";
    const totalSeconds = Math.floor(milliseconds / 1000), ms = Math.floor(milliseconds % 1000);
    const seconds = totalSeconds % 60, totalMinutes = Math.floor(totalSeconds / 60), minutes = totalMinutes % 60;
    const hours = Math.floor(totalSeconds / 3600);
    const tail = `${String(seconds).padStart(2, "0")}.${String(ms).padStart(3, "0")}`;
    return hours ? `${hours}:${String(minutes).padStart(2, "0")}:${tail}` : `${totalMinutes}:${tail}`;
  }

  function formatDuration(value) {
    if (value < 1) return `${value.toFixed(2)}s`;
    const seconds = Math.round(value), minutes = Math.floor(seconds / 60);
    return minutes ? `${minutes}m ${String(seconds % 60).padStart(2, "0")}s` : `${seconds}s`;
  }

  function selectProcess(pid, name) {
    const previous = state.selectedPID;
    state.pendingSelectionIndex = null; state.selectedPID = pid; state.selectedName = name;
    elements.stop.disabled = false; elements.inspect.disabled = false;
    if (previous !== null) state.rowViews.get(previous)?.update(state.rowViews.get(previous).process, state.rowViews.get(previous).index);
    state.rowViews.get(pid)?.update(state.rowViews.get(pid).process, state.rowViews.get(pid).index);
  }

  function clearProcessSelection() {
    const previous = state.selectedPID;
    state.pendingSelectionIndex = null;
    if (previous === null) return;
    state.selectedPID = null; state.selectedName = "";
    elements.stop.disabled = true; elements.inspect.disabled = true;
    const previousView = state.rowViews.get(previous);
    previousView?.update(previousView.process, previousView.index);
  }

  function loadedRowAt(index) {
    for (const view of state.rowViews.values()) {
      if (!view.transient && view.index === index) return view;
    }
    return null;
  }

  function processRowsViewportHeight() {
    return Math.max(1, elements.viewport.clientHeight - TABLE_HEADER_HEIGHT);
  }

  function keepRowVisible(index) {
    const rowTop = index * ROW_HEIGHT;
    const rowBottom = rowTop + ROW_HEIGHT;
    const viewportTop = elements.viewport.scrollTop;
    const viewportHeight = processRowsViewportHeight();
    const viewportBottom = viewportTop + viewportHeight;
    if (rowTop < viewportTop) elements.viewport.scrollTop = rowTop;
    else if (rowBottom > viewportBottom) elements.viewport.scrollTop = Math.max(0, rowBottom - viewportHeight);
  }

  function resolvePendingSelection() {
    if (state.pendingSelectionIndex === null) return false;
    const view = loadedRowAt(state.pendingSelectionIndex);
    if (!view) return false;
    selectProcess(view.pid, view.process.command || "");
    return true;
  }

  function moveProcessSelection(direction) {
    if (!state.total) return;
    let currentIndex = state.pendingSelectionIndex;
    if (currentIndex === null && state.selectedPID !== null) {
      currentIndex = state.rowViews.get(state.selectedPID)?.index ?? null;
    }

    let targetIndex;
    if (currentIndex === null) {
      const firstVisible = Math.max(0, Math.floor(elements.viewport.scrollTop / ROW_HEIGHT));
      const lastVisible = Math.min(
        state.total - 1,
        Math.max(firstVisible, Math.floor((elements.viewport.scrollTop + processRowsViewportHeight() - 1) / ROW_HEIGHT))
      );
      targetIndex = direction > 0 ? firstVisible : lastVisible;
    } else {
      targetIndex = Math.max(0, Math.min(state.total - 1, currentIndex + direction));
    }

    state.pendingSelectionIndex = targetIndex;
    keepRowVisible(targetIndex);
    if (!resolvePendingSelection()) scheduleViewport(true, true);
  }

  async function inspectSelected() {
    if (!state.selectedPID) return;
    const pid = state.selectedPID;
    elements.detailTitle.textContent = state.selectedName || `PID ${pid}`;
    elements.detailBody.innerHTML = '<p class="loading">Loading process details…</p>';
    elements.drawerScrim.hidden = false; elements.drawer.classList.add("open"); elements.drawer.setAttribute("aria-hidden", "false");
    state.detailController?.abort(); const controller = new AbortController(); state.detailController = controller;
    try {
      const response = await fetch(`/api/processes/${pid}`, { cache: "no-store", signal: controller.signal });
      if (!response.ok) throw new Error((await response.text()).trim() || `Request failed (${response.status})`);
      const payload = await response.json(); if (state.selectedPID === pid) renderProcessDetail(payload.process);
    } catch (error) {
      if (error.name !== "AbortError") elements.detailBody.textContent = error.message || "Could not load process details.";
    }
  }

  function renderProcessDetail(process) {
    elements.detailTitle.textContent = process.shortCommand || process.command || `PID ${process.pid}`;
    const grid = document.createElement("div"); grid.className = "detail-grid";
    const details = [
      ["PID", String(process.pid ?? "—")], ["Parent PID", String(process.parentPID ?? "—")], ["User", process.user],
      ["Threads", String(process.threadCount ?? "—")], ["CPU", `${formatDecimal(process.cpuPercent, 1)}%`],
      ["CPU time", formatCPUTime(process.cpuTimeMilliseconds)], ["Resident memory", formatMemory(process.memoryKilobytes)],
      ["Virtual memory", formatMemory(process.virtualMemoryKilobytes)], ["Launched", process.launchTime || "—"],
      ["Parent", process.parentShortCommand || "—"], ["Command line", process.commandLine || process.command, true]
    ];
    for (const [label, value, wide] of details) {
      const item = document.createElement("div"); item.className = `detail-item${wide ? " detail-wide" : ""}`;
      const caption = document.createElement("span"); caption.textContent = label;
      const content = document.createElement("strong"); content.textContent = value ?? "—";
      item.append(caption, content); grid.append(item);
    }
    if (Array.isArray(process.openFiles)) {
      const item = document.createElement("div"); item.className = "detail-item detail-wide";
      const caption = document.createElement("span"); caption.textContent = `Open files (${process.openFiles.length})`;
      const list = document.createElement("ul"); list.className = "open-files";
      for (const file of process.openFiles.slice(0, 100)) {
        const row = document.createElement("li"), code = document.createElement("code");
        code.textContent = `${file.descriptor || ""} ${file.type || ""}  ${file.name || ""}`.trim(); row.append(code); list.append(row);
      }
      item.append(caption, list); grid.append(item);
    }
    elements.detailBody.replaceChildren(grid);
  }

  function closeDrawer() {
    state.detailController?.abort(); elements.drawer.classList.remove("open");
    elements.drawer.setAttribute("aria-hidden", "true"); elements.drawerScrim.hidden = true;
  }

  async function signalSelected(force) {
    const pid = state.selectedPID; if (!pid) return;
    try {
      const response = await fetch(`/api/processes/${force ? "force-quit" : "quit"}?pid=${encodeURIComponent(pid)}`, { cache: "no-store" });
      if (!response.ok) throw new Error((await response.text()).trim() || `Request failed (${response.status})`);
    } catch (error) { window.alert(`Could not stop ${state.selectedName || `PID ${pid}`}: ${error.message}`); }
  }

  function resetQuery() {
    state.total = 0; state.snapshotIndex = 0; state.requestedStart = -1; state.requestedEnd = -1;
    state.pendingSelectionIndex = null;
    elements.viewport.scrollTop = 0; elements.spacer.style.height = `${processRowsViewportHeight()}px`;
    elements.rowStripes.style.height = "0px";
    for (const view of [...state.rowViews.values()]) view.removeNow();
    updateSortIndicators(); scheduleViewport(true, true);
  }

  function updateSortIndicators() {
    document.querySelectorAll("[data-sort]").forEach(button => {
      const active = button.dataset.sort === state.sort;
      const mark = button.querySelector(".sort-mark");
      mark.classList.toggle("visible", active);
      mark.classList.toggle("ascending", active && state.ascending);
      mark.classList.toggle("descending", active && !state.ascending);
      button.setAttribute("aria-sort", active ? (state.ascending ? "ascending" : "descending") : "none");
    });
  }

  function updateHorizontalScrollState() {
    elements.viewport.classList.toggle("has-horizontal-offset", elements.viewport.scrollLeft > .5);
  }

  elements.viewport.addEventListener("scroll", () => {
    updateHorizontalScrollState();
    if (state.scrollTimer) return;
    state.scrollTimer = window.setTimeout(() => { state.scrollTimer = 0; scheduleViewport(); }, 16);
  }, { passive: true });

  document.addEventListener("gesturestart", event => event.preventDefault(), { passive: false });
  document.addEventListener("gesturechange", event => event.preventDefault(), { passive: false });
  document.addEventListener("touchmove", event => {
    if (event.touches.length > 1) event.preventDefault();
  }, { passive: false });

  new ResizeObserver(() => {
    elements.spacer.style.height = `${Math.max(state.total * ROW_HEIGHT, processRowsViewportHeight())}px`;
    updateHorizontalScrollState();
    scheduleViewport(true, true); chart.render();
  }).observe(elements.viewport);

  elements.rows.addEventListener("click", event => {
    const row = event.target.closest(".process-row"); if (row) selectProcess(Number(row.dataset.pid), row.dataset.name || "");
    if (row) elements.viewport.focus({ preventScroll: true });
  });
  elements.rows.addEventListener("dblclick", event => {
    const row = event.target.closest(".process-row");
    if (row) { selectProcess(Number(row.dataset.pid), row.dataset.name || ""); inspectSelected(); }
  });
  document.addEventListener("click", event => {
    if (!(event.target instanceof Element)) return;
    const preservesSelection = event.target.closest(
      ".process-row, button, input, select, textarea, a, label, dialog, .detail-drawer, .drawer-scrim"
    );
    if (!preservesSelection) clearProcessSelection();
  });
  $(".table-header").addEventListener("click", event => {
    const button = event.target.closest("[data-sort]"); if (!button) return;
    if (state.sort === button.dataset.sort) state.ascending = !state.ascending;
    else { state.sort = button.dataset.sort; state.ascending = ["command", "user", "pid"].includes(state.sort); }
    resetQuery();
  });
  elements.search.addEventListener("input", () => {
    clearTimeout(state.searchTimer);
    state.searchTimer = window.setTimeout(() => { state.search = elements.search.value.trim(); resetQuery(); }, 160);
  });
  document.addEventListener("keydown", event => {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "f") {
      event.preventDefault(); elements.search.focus(); elements.search.select();
    }
    if ((event.key === "ArrowUp" || event.key === "ArrowDown") &&
        !event.metaKey && !event.ctrlKey && !event.altKey &&
        !elements.stopDialog.open && !elements.drawer.classList.contains("open") &&
        !(event.target instanceof Element && event.target.closest("input, textarea, select, [contenteditable='true']"))) {
      event.preventDefault();
      elements.viewport.focus({ preventScroll: true });
      moveProcessSelection(event.key === "ArrowDown" ? 1 : -1);
    }
    if (event.key === "Escape") closeDrawer();
  });
  elements.inspect.addEventListener("click", inspectSelected);
  elements.stop.addEventListener("click", () => {
    elements.stopMessage.textContent = `Choose how to stop ${state.selectedName || `PID ${state.selectedPID}`}. Unsaved work in that process may be lost.`;
    elements.stopDialog.showModal();
  });
  elements.stopDialog.addEventListener("close", () => {
    if (elements.stopDialog.returnValue === "quit") signalSelected(false);
    if (elements.stopDialog.returnValue === "force") signalSelected(true);
  });
  elements.closeDrawer.addEventListener("click", closeDrawer);
  elements.drawerScrim.addEventListener("click", closeDrawer);

  const appearanceQuery = window.matchMedia("(prefers-color-scheme: dark)");
  appearanceQuery.addEventListener?.("change", () => {
    buildAtlases(); Object.values(metricSprites).forEach(sprite => sprite.invalidate());
    for (const view of state.rowViews.values()) view.invalidateSprites(); updateMetrics();
  });

  updateSortIndicators(); updateMetrics(); loadCPUHistory(); connectStream();
})();
