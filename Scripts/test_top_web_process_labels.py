#!/usr/bin/env python3
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='top-web-process-labels-') as directory:
    executable = pathlib.Path(directory) / 'test'
    subprocess.run([
        'cc', '-std=gnu17', '-O1', '-g', '-fsanitize=address,undefined',
        str(root / 'Tests/TopWebProcessLabelsTest.c'), str(root / 'Backend/Environment.c'),
        '-framework', 'CoreFoundation', '-lpthread', '-lm', '-o', str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True)
