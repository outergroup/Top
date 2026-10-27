# Top container support

Top owns `outer-top-helper` in [Helper](Helper/README.md). The backend handles host operations directly and reuses long-running container helpers over stdin/stdout. Outer Shell supplies container discovery and installation, not an application-operation proxy.

Container images must install `/usr/local/bin/outer-top-helper`. The bundled base images include each app's separate executable. Custom images can COPY the app's static helper directly. Release, deployment and development scripts build it from this app's Helper directory. The container process exits when its backend connection closes; it is not a separately managed daemon.

The HTML frontend uses the container-aware APIs. Outerframe behavior is unchanged. Docker is tested; Apple container/wslc still require live validation. Native Windows backend integration remains separate.

## Binary data interfaces

Top's HTTP and outerframe data interfaces remain binary. `/api/environments?operation=processes` returns an OETP snapshot directly from TopBackend. Its 80-byte header describes target rows (56 bytes), process rows (112 bytes), and error rows (16 bytes), followed by strings. The additional process fields are target index at 96, host PID at 100, and host-user reference at 104. Host PIDs are zero when unavailable. `Backend/Environment/snapshot.inc` defines the layout and `Resources/TopWeb/environments.js` validates it.

CPU history uses OTCH version 1: a 32-byte header containing magic/version/total-size/count/row-stride/row-offset at offsets 0/4/8/12/16/20, with reserved u64 at 24. Each 40-byte row contains timestamp at 0, availability flag at 8, reserved u32 at 12, and user/system/idle doubles at 16/24/32. Empty history is valid before sampling begins.

Process details and outerframe initialization use OTPD version 1. The 144-byte header contains magic/version/total-size/file-count/file-stride/file-offset/variable-offset/kernel-flag at 0/4/8/12/16/20/24/28; timestamp at 32; PID/parent PID at 40/44; CPU double at 48; RSS KB/VSZ KB/CPU milliseconds as u64 at 56/64/72; thread count at 80 and reserved u32 at 84. String references for user/full command/short command/parent command/launch time/open-files error are at 88/96/104/112/120/128; reserved u64 at 136. Open-file rows are 24 bytes with descriptor/type/path string references.

All integers are little-endian. String references are absolute u32 offsets and byte lengths; text is UTF-8. `Scripts/test_top_binary.py` exercises the C producer and actual Swift/JavaScript decoders. `Scripts/test_environment_snapshot.cjs` covers helper snapshot decoding, fallback collection and malformed packets. HTTP errors and signal acknowledgements are plain text; Top has no JSON data interfaces.
