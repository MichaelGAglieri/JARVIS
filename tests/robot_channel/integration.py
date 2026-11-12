#!/usr/bin/env python3
"""Full native bridge + Swift transport smoke test in isolated Anteprima only."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(sys.argv[1]).resolve()
SWIFT = Path(sys.argv[2]).resolve()
with tempfile.TemporaryDirectory(prefix='jrc-', dir='/private/tmp') as directory:
    env = dict(os.environ, DOC_REGIA_DATA=directory, DOC_REGIA_NO_HARDWARE='1',
               PYTHONPATH=str(ROOT), PYTHONDONTWRITEBYTECODE='1')
    process = subprocess.Popen([sys.executable, '-u', str(ROOT/'native/native_bridge.py')],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, env=env, cwd=ROOT)
    def native(op, **kwargs):
        request = dict(op=op, jarvis_ui=dict(speed_pending=False, return_home=False), **kwargs)
        process.stdin.write(json.dumps(request)+'\n');process.stdin.flush()
        result=json.loads(process.stdout.readline())
        assert 'error' not in result, result.get('error')
        return result
    path = str(Path(directory)/'jarvis/control.sock')
    def wire(op, **kwargs):
        native('heartbeat')
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(3);client.connect(path)
            client.sendall(json.dumps(dict(op='status')).encode()+b'\n')
            state=json.loads(client.makefile('rb').readline())
        request=dict(op=op,session=state['session'],epoch=state['epoch'],id=str(uuid.uuid4()),expires=time.time()+20,**kwargs)
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(3);client.connect(path);client.sendall(json.dumps(request).encode()+b'\n')
            return json.loads(client.makefile('rb').readline())
    def wait():
        end=time.monotonic()+8
        while time.monotonic()<end:
            result=native('heartbeat')['state']
            if not result['busy'] and not result['playing']:
                return result
            time.sleep(.04)
        raise AssertionError('Anteprima timeout')
    try:
        first=native('heartbeat');assert not first['state']['connected']
        subprocess.run([str(SWIFT),path],check=True)
        native('connect',mode='demo');native('home_set');native('limits',limits=[[-5,5]]*6)
        native('studio_operator_collisions',enabled=False,confirmed=True)
        start=time.monotonic()
        reply=wire('jog',joint=1,degrees=1,mode='relative');assert reply['ok'],reply
        accepted=time.monotonic()-start
        assert wait()['pos'][0]==1
        print('PASS: native Anteprima relative jog; command accepted in %.3f s' % accepted)
        native('record',name='allineamento 1',dwell=0)
        reply=wire('jog',joint=1,degrees=2,mode='absolute');assert reply['ok'],reply
        assert wait()['pos'][0]==2
        native('record',name='allineamento 2',dwell=0)
        before=native('heartbeat')['state']['sequence']
        reply=wire('sequence');assert reply['ok'],reply
        after=wait();assert after['pos'][0]==2 and after['cycle']==1
        assert after['sequence']==before
        assert not wire('jog',joint=1,degrees=20,mode='relative')['ok']
        assert wire('quit')['ok']
        reply=native('heartbeat');assert reply['jarvis_quit'] and not reply['state']['home']
        print('PASS: absolute jog, single sequence, unchanged poses, limit refusal and STOP/quit handoff')
        process.stdin.close();assert process.wait(timeout=5)==0
        assert not Path(path).exists()
        print('PASS: EOF cleanup removes private socket')
    finally:
        if process.poll() is None:process.kill();process.wait()
        stderr=process.stderr.read()
        if stderr:print(stderr,file=sys.stderr)
        process.stdout.close();process.stderr.close()
