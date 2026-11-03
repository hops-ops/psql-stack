#!/usr/bin/env python3
"""Execute the shared CompositionTest contracts with up's native renderer."""
import copy
import json
from pathlib import Path
import subprocess
import tempfile
import time
import yaml

ROOT = Path(__file__).resolve().parents[2]
CASES = json.loads((ROOT / 'tests/test-backup/cases.json').read_text())

def subset(expected, actual, path=''):
    if isinstance(expected, dict):
        assert isinstance(actual, dict), path
        for k,v in expected.items():
            assert k in actual, path + '.' + k
            subset(v,actual[k],path+'.'+k)
    elif isinstance(expected, list):
        assert len(expected) == len(actual), (path, expected, actual)
        for i,(e,a) in enumerate(zip(expected,actual)):
            subset(e,a,path+f'[{i}]')
    else:
        assert actual == expected, (path, expected, actual)

def render(spec):
    (ROOT / '.tmp').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=ROOT / '.tmp') as tmp:
        tmp=Path(tmp); xr=tmp/'xr.yaml';xr.write_text(yaml.safe_dump(spec['xr']))
        command=['up','composition','render','--xrd='+spec['xrdPath'],spec['compositionPath'],str(xr),'--quiet']
        if spec.get('observedResources'):
            observed=tmp/'observed';observed.mkdir()
            for i,obj in enumerate(spec['observedResources']):
                (observed/f'{i}.yaml').write_text(yaml.safe_dump(obj))
            command+=['--observed-resources='+str(observed)]
        for attempt in range(3):
            p=subprocess.run(command,cwd=ROOT,text=True,capture_output=True,timeout=180)
            # Retry transport failures only; a composition rejection is evidence.
            if p.returncode and any(s in p.stderr for s in ['no such host','unexpected EOF','TLS handshake timeout','connection reset by peer']):
                if attempt < 2:
                    time.sleep(2)
                    continue
            break
        return p,list(yaml.safe_load_all(p.stdout)) if p.returncode==0 else []

for case in CASES:
    p,docs=render(case['spec'])
    assert p.returncode==0,(case['metadata']['name'],p.stderr)
    for expected in case['spec']['assertResources']:
        found=[d for d in docs if d and d.get('kind')==expected['kind'] and d.get('metadata',{}).get('name')==expected.get('metadata',{}).get('name')]
        assert len(found)==1,(case['metadata']['name'],expected)
        subset(expected,found[0],case['metadata']['name'])
    # Restore bootstrap must never contain initdb or an enabled WAL archiver.
    if case['spec']['xr']['spec'].get('restore'):
        cluster=next(d['spec']['forProvider']['manifest'] for d in docs if d and d['kind']=='Object' and d['spec']['forProvider']['manifest']['kind']=='Cluster')
        assert 'initdb' not in cluster['spec']['bootstrap']
        assert not any(p.get('isWALArchiver') for p in cluster['spec'].get('plugins',[]))
    print('PASS '+case['metadata']['name'],flush=True)

base=copy.deepcopy(CASES[0]['spec'])
invalid=[]
def reject(name,modify,message):
    spec=copy.deepcopy(base);modify(spec['xr']['spec']);invalid.append((name,spec,message))
reject('missing-destination',lambda s:s['backup'].pop('destinationPath'),'destinationPath')
reject('missing-auth',lambda s:s['backup'].pop('credentials'),'credentials')
reject('ambiguous-auth',lambda s:s['backup']['credentials'].update(accessKeyId={'name':'x','key':'a'},secretAccessKey={'name':'x','key':'b'}),'credentials')
reject('five-field-cron',lambda s:s['backup']['schedule'].update(cron='0 6 * * *'),'six UTC')
reject('owned-store-conflict',lambda s:s['backup'].update(existingObjectStore=True),'observe-only')
reject('full-override-conflict',lambda s:s.update(cnpg={'overrideAllValues':{'instances':1}}),'overrideAllValues')
for field in ['bootstrap','externalClusters','backup']:
    reject('passthrough-'+field,lambda s,f=field:s.update(cnpg={'values':{f:{'conflict':True}}}),'typed backup/restore owns')
reject('duplicate-barman-plugin',lambda s:s.update(cnpg={'values':{'plugins':[{'name':'barman-cloud.cloudnative-pg.io'}]}}),'Remove the Barman')
identity=copy.deepcopy(next(c['spec'] for c in CASES if c['metadata']['name']=='existing-applied-archive-identity'))
identity['xr']['spec']['backup']['serverName']='different-server'
invalid.append(('archive-identity-change',identity,'archive identity differs'))
reject('competing-wal-plugin',lambda s:s.update(cnpg={'values':{'plugins':[{'name':'other.example','isWALArchiver':True}]}}),'owns the WAL archiver')
restore_case=copy.deepcopy(next(c['spec'] for c in CASES if c['metadata']['name']=='restore-latest'))
for name, change, message in [
    ('same-source-identity',lambda s:s['restore']['source'].update(serverName='app-db'),'different from the new cluster'),
    ('time-without-base',lambda s:s['restore'].update(target={'targetTime':'2026-11-02T12:15:00Z'}),'backupID'),
    ('conflicting-targets',lambda s:s['restore'].update(target={'backupID':'20261102T120000','targetTime':'2026-11-02T12:15:00Z','targetName':'before'}),'choose targetTime or targetName'),
    ('restore-with-writes',lambda s:s.update(backup=copy.deepcopy(base['xr']['spec']['backup'])),'cannot enable backups'),
]:
    spec=copy.deepcopy(restore_case);change(spec['xr']['spec']);invalid.append((name,spec,message))
for name,spec,message in invalid:
    p,_=render(spec)
    assert p.returncode!=0 and message in p.stderr,(name,p.returncode,p.stderr)
    print('PASS reject-'+name,flush=True)
print(f'{len(CASES)+len(invalid)} render contracts passed',flush=True)
