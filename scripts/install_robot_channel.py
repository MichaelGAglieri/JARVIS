#!/usr/bin/env python3
"""Install/restore only the two reviewed app bundles, with hash-verified backups.
Dry-run unless --apply. Never stops or launches Robot Console or touches its data.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import time
import uuid

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/robot-channel-2026-11-09'
NAMES=('JARVIS','Robot Console')


def hashes(folder):
    return {str(p.relative_to(folder)):hashlib.sha256(p.read_bytes()).hexdigest() for p in folder.rglob('*') if p.is_file()}


def verify(folder):
    subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(folder)],check=True)


def processes():
    return subprocess.check_output(['/bin/ps','-axo','command='],text=True).splitlines()


def jarvis_running():
    return any(line.strip().startswith('/Applications/JARVIS.app/Contents/MacOS/JARVIS') for line in processes())


def config_hashes():
    folder=Path.home()/'Library/Application Support/JARVIS'
    return {name:hashlib.sha256((folder/name).read_bytes()).hexdigest() for name in ['config.json','protocolli.json'] if (folder/name).exists()}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply',action='store_true')
    parser.add_argument('--rollback',action='store_true')
    args=parser.parse_args()
    manifest=json.loads((OUT/'bundle-manifest.json').read_text())
    source=OUT/('previous-apps' if args.rollback else 'staged')
    expected='previous' if args.rollback else 'staged'
    current_expected='staged' if args.rollback else 'previous'
    for name in NAMES:
        app=source/(name+'.app');target=Path('/Applications')/(name+'.app')
        verify(app)
        if hashes(app)!=manifest[name][expected]:raise RuntimeError('Prepared bundle changed: '+name)
        if hashes(target)!=manifest[name][current_expected]:raise RuntimeError('Installed app changed since snapshot: '+name)
    if any('.app/Contents/MacOS/DOCRegia' in line and not line.lstrip().startswith(('python','/opt/homebrew/bin/python')) for line in processes()):
        raise RuntimeError('Robot Console is running. Close it before installation; this installer never stops the robot.')
    print(('Restore' if args.rollback else 'Install')+' reviewed bundles; Robot Console remains closed.')
    if not args.apply:return
    was_running=jarvis_running()
    before=config_hashes()
    if was_running:
        subprocess.run(['/usr/bin/osascript','-e','tell application "/Applications/JARVIS.app" to quit'],check=True)
        end=time.monotonic()+10
        while jarvis_running() and time.monotonic()<end:time.sleep(.2)
        if jarvis_running():raise RuntimeError('JARVIS did not quit; no app replaced.')
    transaction=OUT/('restore-' if args.rollback else 'install-')/uuid.uuid4().hex
    transaction.mkdir(parents=True)
    replaced=[]
    try:
        for name in NAMES:
            target=Path('/Applications')/(name+'.app')
            stage=Path('/Applications')/('.'+name+'-channel-'+uuid.uuid4().hex+'.app')
            subprocess.run(['/usr/bin/ditto',str(source/(name+'.app')),str(stage)],check=True)
            verify(stage)
            target.rename(transaction/(name+'.app'))
            replaced.append(name)
            stage.rename(target)
            verify(target)
            if hashes(target)!=manifest[name][expected]:raise RuntimeError('Installed bundle hash mismatch: '+name)
    except Exception:
        for name in reversed(replaced):
            target=Path('/Applications')/(name+'.app')
            if target.exists():target.rename(transaction/(name+'-failed.app'))
            (transaction/(name+'.app')).rename(target)
        if was_running:subprocess.run(['/usr/bin/open','/Applications/JARVIS.app'],check=True)
        raise
    after=config_hashes()
    result=dict(action='rollback' if args.rollback else 'install',previous_apps=str(transaction),
                configurations_unchanged=before==after,robot_console_launched=False,jarvis_restarted=was_running,
                bundle_hashes_verified=True)
    if was_running:
        subprocess.run(['/usr/bin/open','/Applications/JARVIS.app'],check=True)
        end=time.monotonic()+10
        while not jarvis_running() and time.monotonic()<end:time.sleep(.2)
        result['jarvis_running']=jarvis_running()
    (OUT/('rollback-result.json' if args.rollback else 'install-result.json')).write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))

if __name__=='__main__':main()
