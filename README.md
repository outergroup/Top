# Top

Like 'top', but with a capital 'T' and a graphical user interface. Top is an [outerframe](https://github.com/outergroup/outerframe) app built especially for [Outer Loop](https://outerloop.sh).

It's built from two pieces:

- `Top`: the macOS user interface in `Frontend/`.
- `TopBackend`: the HTTP server in `Backend/main.c`.

## Deploy To Localhost

With a current Outer Shell installed on the Mac:

```bash
./app target local
./app deploy
```

This builds a universal macOS backend and frontend, assembles a complete
`Top.app` payload containing the native bundles and browser assets, and installs
it through local Outer Shell. It then appears in Outer Loop's localhost app
list. The default is a user-scoped install.

To deploy locally once without replacing a saved SSH target:

```bash
./app deploy --local
```

`./app status --local`, `./app logs --local`, and
`./app uninstall --local` provide the corresponding local operations.

## Deploy Over SSH

With a current Outer Shell installed on the target:

```bash
./app target "ssh -p 22 you@server"
./app deploy
```

The target lives in the gitignored `target.env`. The command builds the
universal frontend, detects the target architecture and libc, builds the one
matching Linux backend, streams the payload over SSH, and installs it through
Outer Shell. glibc builds use the manylinux2014 (glibc 2.17) baseline; musl
builds use musllinux 1.2. Run `./app build-matrix` to build all four Linux
release variants, or `./app help` for the other development commands.

## Build

From this directory:

```bash
xcodebuild -project Top.xcodeproj -scheme Top -configuration Release build
xcodebuild -project Top.xcodeproj -scheme TopBackend -configuration Release build
```

The checked-in project does not contain a personal Apple development team.
`Top` builds unsigned content bundles, and `TopBackend` uses ad-hoc signing.
If a private release flow needs a specific Apple team, pass it as an
`xcodebuild` setting from that private build environment.

## Run On macOS

```bash
PORT=7351
BUILD_ROOT="$PWD/build/macos"
RUN_ROOT="$PWD/build/run"

xcodebuild -project Top.xcodeproj -scheme Top -configuration Release SYMROOT="$BUILD_ROOT" build
xcodebuild -project Top.xcodeproj -scheme TopBackend -configuration Release SYMROOT="$BUILD_ROOT" build

rm -rf "$RUN_ROOT"
mkdir -p "$RUN_ROOT/bundles" "$RUN_ROOT/web"
Scripts/archive_top_bundle.sh "$BUILD_ROOT/Release/Top.bundle" "$RUN_ROOT/bundles"
cp Resources/TopWeb/* "$RUN_ROOT/web/"

"$BUILD_ROOT/Release/TopBackend" --port "$PORT" --bundles-dir "$RUN_ROOT/bundles"

# or use sudo to see more processes and details
sudo "$BUILD_ROOT/Release/TopBackend" --port "$PORT" --bundles-dir "$RUN_ROOT/bundles"
```

Open `http://127.0.0.1:7351/` in [Outer Loop](https://outerloop.sh),
[Outer Frame](https://github.com/outergroup/outerframe), or a browser. Browsers
receive the HTML/JavaScript process monitor in `Resources/TopWeb`. Its
virtualized table tells the backend which row range is visible and the backend
streams only that viewport. Clients that send
`Outerframe-Accept: application/vnd.outerframe` continue to receive the native
Top frontend descriptor.

The browser frontend follows the native frontend's retained rendering model:

- The process viewport keeps a bounded set of DOM rows keyed by PID. Snapshot
  updates change their CSS transforms, while the backend's `previousIndex` and
  `additionalEntries` fields let rows animate into or through the viewport.
- Numeric cells keep fixed glyph layers backed by generated digit,
  punctuation, and `KB`/`MB`/`GB` sprite atlases. An update changes only glyph
  layers whose atlas position actually changed.
- The CPU chart owns a fixed pool of retained bar elements. Dragging its
  selection handles uses trailing requests when the range ends at Now and
  fixed `/api/processes/history` requests for historical ranges.

There is no animation frame rendering loop. Row movement is performed by CSS
transitions and new rows with offscreen previous indexes use CSS keyframes.

For Outer Loop-managed deployments, prefer a Unix socket. If `--port` is omitted, Top listens directly under `$XDG_RUNTIME_DIR` using the backend label:

```bash
"$BUILD_ROOT/Release/TopBackend" \
  --label org.outershell.Top \
  --bundles-dir "$RUN_ROOT/bundles"
```

You can also pass an explicit socket:

```bash
"$BUILD_ROOT/Release/TopBackend" \
  --socket-path "$XDG_RUNTIME_DIR/org.outershell.Top" \
  --label org.outershell.Top \
  --bundles-dir "$RUN_ROOT/bundles"
```


## Build For Linux

Top's frontend is a macOS outerframe bundle, so build the frontend archives on macOS first:

```bash
BUILD_ROOT="$PWD/build/frontend"
PACKAGE_ROOT="$PWD/build/linux-package"

xcodebuild -project Top.xcodeproj -scheme Top -configuration Release \
  SYMROOT="$BUILD_ROOT" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  build

rm -rf "$PACKAGE_ROOT"
mkdir -p "$PACKAGE_ROOT/bundles"
Scripts/archive_top_bundle.sh "$BUILD_ROOT/Release/Top.bundle" "$PACKAGE_ROOT/bundles"
```

Then build the backend on Linux from this directory:

```bash
cc -std=gnu17 -O2 -o TopBackend Backend/main.c -lm
```

Copy `TopBackend`, the `bundles` directory, and `Resources/TopWeb` (as `web`)
onto the Linux machine, then run:

```bash
PORT=7351
./TopBackend --port "$PORT" --bundles-dir ./bundles

# or use sudo to see more processes and details
sudo ./TopBackend --port "$PORT" --bundles-dir ./bundles
```

`TopBackend` binds TCP ports to loopback only. If you are running it on a remote Linux machine and you're using Outer Frame, connect with SSH port forwarding:

```bash
ssh -L 7351:127.0.0.1:7351 user@linux-host
```

Then open `http://127.0.0.1:7351/` on your local machine. You can avoid all of this if you use Outer Loop to launch and connect to Top over SSH.

`TopBackend` serves the native frontend from
`TopContent.bundle.macos-arm.aar` and `TopContent.bundle.macos-x86.aar`. The
`--bundles-dir` argument must point to the directory containing those `.aar`
files, not to the built `Top.bundle` directory. It also looks for the browser
frontend in a sibling `web` directory; pass `--web-root DIR` to override that
location.

To create an Outer Shell starter app release payload, build both Linux backend
architectures into `build/linux-package/RemoteLinuxBinaries`, then run:

```bash
./Scripts/package_release.sh
```

The packaging script also builds the macOS `TopBackend` and writes an archive
with `Top.app` for localhost macOS installs plus `RemoteLinuxBinaries`,
top-level Linux content bundles, browser assets, and the app icon to
`build/release/Top.tar.gz`. Deployment-specific publishing should live outside
this repository.
