# Top

Like 'top', but with a capital 'T' and a graphical user interface. Top is an [outerframe](https://github.com/outergroup/outerframe) app built especially for [Outer Loop](https://outerloop.sh).

It's built from two pieces:

- `Top`: the macOS user interface in `Frontend/`.
- `TopBackend`: the HTTP server in `Backend/main.c`.

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
mkdir -p "$RUN_ROOT/bundles"
Scripts/archive_top_bundle.sh "$BUILD_ROOT/Release/Top.bundle" "$RUN_ROOT/bundles"

"$BUILD_ROOT/Release/TopBackend" --port "$PORT" --bundles-dir "$RUN_ROOT/bundles"

# or use sudo to see more processes and details
sudo "$BUILD_ROOT/Release/TopBackend" --port "$PORT" --bundles-dir "$RUN_ROOT/bundles"
```

Open `http://127.0.0.1:7351/` in [Outer Loop](https://outerloop.sh) or [Outer Frame](https://github.com/outergroup/outerframe).

For Outer Loop-managed deployments, prefer a Unix socket. If `--port` is omitted, Top listens directly under `$XDG_RUNTIME_DIR` using the backend label:

```bash
"$BUILD_ROOT/Release/TopBackend" \
  --label dev.outergroup.Top \
  --bundles-dir "$RUN_ROOT/bundles"
```

You can also pass an explicit socket:

```bash
"$BUILD_ROOT/Release/TopBackend" \
  --socket-path "$XDG_RUNTIME_DIR/dev.outergroup.Top" \
  --label dev.outergroup.Top \
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

Copy `TopBackend` and the `bundles` directory from `build/linux-package` onto the Linux machine, then run:

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

`TopBackend` serves the frontend from `TopContent.bundle.macos-arm.aar` and `TopContent.bundle.macos-x86.aar`. The `--bundles-dir` argument must point to the directory containing those `.aar` files, not to the built `Top.bundle` directory.

To create a release payload for a Home Screen-style installer, build both Linux
backend architectures into `build/linux-package/RemoteLinuxBinaries`, then run:

```bash
./Scripts/package_release.sh
```

The archive is written to `build/release/Top.tar.gz`. Deployment-specific
publishing should live outside this repository.
