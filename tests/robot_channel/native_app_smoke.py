#!/usr/bin/env python3
"""Launch the staged native GUI with temporary data and hardware forbidden.
Verify its actual STOP/quit callback, not only the Python request flag.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import uuid

app=Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='jrc-gui-',dir='/private/tmp') as folder:
    env=dict(os.environ,DOC_REGIA_DATA=folder,DOC_REGIA_NO_HARDWARE='1',PYTHONDONTWRITEBYTECODE='1')
    process=subprocess.Popen([str(app/'Contents/MacOS/DOCRegia')],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,text=True)
    path=str(Path(folder)/'jarvis/control.sock')
    def call(data):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(3);client.connect(path);client.sendall(json.dumps(data).encode()+b'\n')
            return json.loads(client.makefile('rb').readline())
    try:
        end=time.monotonic()+15
        while not Path(path).exists() and time.monotonic()<end:
            assert process.poll() is None,'GUI exited during startup'
            time.sleep(.1)
        status=call(dict(op='status'))
        assert not status['state']['connected'] and status['state']['mode']=='demo'
        time.sleep(.6)
        result=call(dict(op='quit',id=str(uuid.uuid4()),session=status['session'],expires=time.time()+5))
        assert result['ok'],result
        assert process.wait(timeout=10)==0
        end=time.monotonic()+3
        while Path(path).exists() and time.monotonic()<end:time.sleep(.1)
        assert not Path(path).exists(),'Native backend did not clean up'
        print('PASS: actual native GUI started disconnected, consumed private quit request and exited with STOP; hardware forbidden')
    finally:
        if process.poll() is None:process.terminate();process.wait(timeout=5)
        errors=process.stderr.read();process.stderr.close()
        if errors:print(errors,file=sys.stderr)
