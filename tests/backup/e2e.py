#!/usr/bin/env python3
"""Seeded recovery drill against rendered PSQL XR output in a disposable kind cluster.

Installs actual CNPG/Barman controllers. The existing up E2E suite separately
checks Crossplane/provider reconciliation; this drill checks the physical data.
"""
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import yaml

CONTEXT = sys.argv[1]
if not CONTEXT.startswith('kind-psql-backup-e2e-'):
    raise SystemExit('Refusing a non-disposable context: ' + CONTEXT)
NS = 'backup-drill'
ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = Path(os.environ.get('BACKUP_EVIDENCE_DIR', ROOT / '_output/backup-evidence'))
EVIDENCE.mkdir(parents=True, exist_ok=True)
# Isolate Helm's cache/config from unrelated repositories on the developer host.
_HELM_DIR = tempfile.TemporaryDirectory(prefix='psql-backup-helm-')
os.environ['HELM_REPOSITORY_CONFIG'] = str(Path(_HELM_DIR.name) / 'repositories.yaml')
os.environ['HELM_REPOSITORY_CACHE'] = str(Path(_HELM_DIR.name) / 'cache')
PROOF = {'context' : CONTEXT, 'started': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'restores': {}}

def run(*args, input=None, timeout=120):
    p = subprocess.run(args, input=input, text=True, capture_output=True, timeout=timeout, cwd=ROOT)
    if p.returncode:
        raise RuntimeError(' '.join(args[:8]) + '\n' + p.stderr[-5000:] + p.stdout[-2000:])
    return p.stdout

def kube(*args, **kw):
    return run('kubectl', '--context', CONTEXT, *args, **kw)

def apply(obj):
    return kube('apply', '-f', '-', input=yaml.safe_dump(obj))

def get(kind, name):
    return json.loads(kube('-n', NS, 'get', kind, name, '-o', 'json'))

def wait(check, description, timeout=900):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                print(description, flush=True)
                return result
        except (RuntimeError, KeyError, subprocess.TimeoutExpired) as e:
            last = str(e)[-800:]
        time.sleep(5)
    raise RuntimeError('Timed out: ' + description + '\n' + str(last))

def render(kind, name, spec):
    plural = {'PSQLStack': 'psqlstacks', 'PSQLCluster': 'psqlclusters'}[kind]
    (ROOT / '.tmp').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=ROOT / '.tmp') as tmp:
        path = Path(tmp) / 'xr.yaml'
        path.write_text(yaml.safe_dump({'apiVersion': 'hops.ops.com.ai/v1alpha1', 'kind': kind,
            'metadata': {'name': name, 'namespace': NS}, 'spec': spec}))
        docs = list(yaml.safe_load_all(run('up', 'composition', 'render',
            '--xrd=apis/' + plural + '/definition.yaml', 'apis/' + plural + '/composition.yaml', str(path), '--quiet', timeout=300)))
    return [d for d in docs if d and d['kind'] not in ['PSQLStack', 'PSQLCluster', 'Usage']]

def cluster_spec(**extra):
    return {'clusterName': 'disposable', 'storage': {'size': '1Gi', 'class': 'standard'},
        'monitoring': {'enabled': False}, 'branching': {'enabled': False}, **extra}

def primary(name):
    return get('clusters.postgresql.cnpg.io', name)['status']['currentPrimary']

def sql(name, statement):
    return kube('-n', NS, 'exec', primary(name), '-c', 'postgres', '--', 'psql', '-U', 'postgres', '-d', 'app', '-At', '-v', 'ON_ERROR_STOP=1', '-c', statement).strip()

def ready(name):
    return any(c['type'] == 'Ready' and c['status'] == 'True' for c in get('clusters.postgresql.cnpg.io', name).get('status', {}).get('conditions', []))

def archive(name):
    lsn = sql(name, 'SELECT pg_current_wal_lsn();')
    segment = sql(name, f"SELECT pg_walfile_name('{lsn}'::pg_lsn);")
    sql(name, 'SELECT pg_switch_wal();')
    wait(lambda: sql(name, "SELECT COALESCE(last_archived_wal, '') FROM pg_stat_archiver;") >= segment, 'WAL archived: ' + segment)

try:
    apply({'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': {'name': NS}})
    # Exercise admission transitions against a real API server. The physical
    # drill below applies rendered target manifests; this CRD needs no controller.
    xrd=yaml.safe_load((ROOT/'apis/psqlclusters/definition.yaml').read_text())
    apply({'apiVersion':'apiextensions.k8s.io/v1','kind':'CustomResourceDefinition',
        'metadata':xrd['metadata'],'spec':{'group':xrd['spec']['group'],'names':xrd['spec']['names'],
        'scope':'Namespaced','versions':[{'name':v['name'],'served':v['served'],'storage':v['referenceable'],'schema':v['schema']} for v in xrd['spec']['versions']]}})
    kube('wait','--for=condition=Established','crd/psqlclusters.hops.ops.com.ai','--timeout=60s')
    guard={'apiVersion':'hops.ops.com.ai/v1alpha1','kind':'PSQLCluster','metadata':{'name':'bootstrap-guard','namespace':NS},'spec':cluster_spec()}
    apply(guard)
    guard['spec']['restore']={'source':{'objectStoreName':'read-only','serverName':'seeded'}}
    try:
        apply(guard)
    except RuntimeError as e:
        assert 'bootstrap-only' in str(e),str(e)
    else:
        raise AssertionError('Admission allowed converting an initialized claim to a restore')
    PROOF['bootstrap_transition_rejected']=True
    # Versions are deliberately explicit and recorded. No current context changes.
    run('helm', 'upgrade', '--install', 'cert-manager', 'cert-manager', '--repo', 'https://charts.jetstack.io', '--version', 'v1.19.1', '--namespace', 'cert-manager', '--create-namespace', '--kube-context', CONTEXT, '--set', 'crds.enabled=true', '--wait', '--timeout', '10m', timeout=660)
    stack = render('PSQLStack', 'drill', {'clusterName': 'disposable', 'scaleToZeroPlugin': {'enabled': False}, 'storageClass': {'enabled': False}, 'snapshotClass': {'enabled': False}, 'backupPlugin': {'enabled': True}})
    for release in stack:
        # Atlas is covered by the package's existing EKS E2E suite.
        if release['kind'] != 'Release' or release['metadata']['name'] == 'atlas-operator':
            continue
        f = release['spec']['forProvider']
        with tempfile.NamedTemporaryFile('w', suffix='.yaml') as values:
            yaml.safe_dump(f.get('values', {}), values); values.flush()
            run('helm', 'upgrade', '--install', release['metadata']['name'], f['chart']['name'], '--repo', f['chart']['repository'], '--version', f['chart']['version'], '--namespace', f['namespace'], '--create-namespace', '--kube-context', CONTEXT, '-f', values.name, '--wait', '--timeout', '10m', timeout=660)
        PROOF.setdefault('charts', []).append(f['chart'])
    # These credentials exist only inside this disposable fixture.
    apply({'apiVersion':'v1','kind':'Secret','metadata':{'name':'object-store','namespace':NS},'stringData':{'ACCESS_KEY_ID':'drill-root','ACCESS_SECRET_KEY':'drill-root-password','RESTORE_KEY_ID':'drill-restore','RESTORE_SECRET_KEY':'drill-restore-password'}})
    apply({'apiVersion':'apps/v1','kind':'Deployment','metadata':{'name':'object-store','namespace':NS},'spec':{'replicas':1,'selector':{'matchLabels':{'app':'object-store'}},'template':{'metadata':{'labels':{'app':'object-store'}},'spec':{'containers':[{'name':'minio','image':'quay.io/minio/minio:RELEASE.2025-04-22T22-12-26Z','args':['server','/data'],'env':[{'name':'MINIO_ROOT_USER','value':'drill-root'},{'name':'MINIO_ROOT_PASSWORD','value':'drill-root-password'}],'ports':[{'containerPort':9000}],'resources':{'requests':{'cpu':'100m','memory':'256Mi'}}}]}}}})
    apply({'apiVersion':'v1','kind':'Service','metadata':{'name':'object-store','namespace':NS},'spec':{'selector':{'app':'object-store'},'ports':[{'port':9000,'targetPort':9000}]}})
    policy = {'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':['s3:GetBucketLocation','s3:ListBucket'],'Resource':['arn:aws:s3:::backups']},{'Effect':'Allow','Action':['s3:GetObject'],'Resource':['arn:aws:s3:::backups/*']}]}
    command = '''set -eu
until mc alias set fixture http://object-store:9000 drill-root drill-root-password; do sleep 2; done
mc mb --ignore-existing fixture/backups
mc admin user add fixture drill-restore drill-restore-password
printf '%s' "$READ_POLICY" >/tmp/read-policy.json
mc admin policy create fixture restore-read-only /tmp/read-policy.json
mc admin policy attach fixture restore-read-only --user drill-restore
mc alias set readonly http://object-store:9000 drill-restore drill-restore-password
printf guard >/tmp/guard
mc cp /tmp/guard fixture/backups/guard
if mc cp /tmp/guard readonly/backups/forbidden-write; then exit 1; fi
if mc rm readonly/backups/guard; then exit 1; fi
mc stat readonly/backups/guard
'''
    apply({'apiVersion':'batch/v1','kind':'Job','metadata':{'name':'prepare-store','namespace':NS},'spec':{'backoffLimit':2,'template':{'spec':{'restartPolicy':'Never','containers':[{'name':'prepare','image':'quay.io/minio/mc:RELEASE.2025-04-16T18-13-26Z','command':['/bin/sh','-c',command],'env':[{'name':'READ_POLICY','value':json.dumps(policy)}]}]}}}})
    kube('-n', NS, 'wait', '--for=condition=complete', 'job/prepare-store', '--timeout=180s', timeout=200)
    PROOF['read_only_source_permissions_verified'] = True
    backup = {'enabled':True, 'destinationPath':'s3://backups/drill', 'endpointURL':'http://object-store:9000', 'credentials':{'accessKeyId':{'name':'object-store','key':'ACCESS_KEY_ID'},'secretAccessKey':{'name':'object-store','key':'ACCESS_SECRET_KEY'}}, 'schedule':{'enabled':False}, 'managementPolicies':['*']}
    resources = render('PSQLCluster', 'seeded', cluster_spec(backup=backup))
    for obj in sorted(resources, key=lambda x: x['spec']['forProvider']['manifest']['kind'] != 'ObjectStore'):
        apply(obj['spec']['forProvider']['manifest'])
    wait(lambda: ready('seeded'), 'Seeded database ready')
    wait(lambda: any(p['name'] == 'barman-cloud.cloudnative-pg.io' for p in get('clusters.postgresql.cnpg.io','seeded').get('status',{}).get('pluginStatus',[])), 'Barman registered')
    sql('seeded', "CREATE TABLE recovery_proof(id integer PRIMARY KEY, value text NOT NULL); INSERT INTO recovery_proof VALUES (1, 'before');")
    apply({'apiVersion':'postgresql.cnpg.io/v1','kind':'Backup','metadata':{'name':'seeded-base','namespace':NS},'spec':{'cluster':{'name':'seeded'},'target':'primary','method':'plugin','pluginConfiguration':{'name':'barman-cloud.cloudnative-pg.io'}}})
    done = wait(lambda: (b if b.get('status',{}).get('phase') == 'completed' else False) if (b := get('backups.postgresql.cnpg.io','seeded-base')) else False, 'Physical base backup completed')
    backup_id = done['status']['backupId']
    sql('seeded', "SELECT pg_create_restore_point('before_change');")
    target_time = sql('seeded', "SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"');")
    time.sleep(2)
    sql('seeded', "UPDATE recovery_proof SET value='after' WHERE id=1; INSERT INTO recovery_proof VALUES(2, 'new');")
    archive('seeded')
    readonly = {'apiVersion':'barmancloud.cnpg.io/v1','kind':'ObjectStore','metadata':{'name':'source-readonly','namespace':NS},'spec':{'configuration':{'destinationPath':'s3://backups/drill','endpointURL':'http://object-store:9000','s3Credentials':{'accessKeyId':{'name':'object-store','key':'RESTORE_KEY_ID'},'secretAccessKey':{'name':'object-store','key':'RESTORE_SECRET_KEY'}},'wal':{'compression':'gzip'}}}}
    apply(readonly)
    for mode, target in [('latest', {}), ('time', {'backupID':backup_id,'targetTime':target_time}), ('named', {'backupID':backup_id,'targetName':'before_change'})]:
        name = 'recovered-' + mode
        rendered = render('PSQLCluster', name, cluster_spec(restore={'source':{'objectStoreName':'source-readonly','serverName':'seeded'},'target':target}))
        manifest = next(o['spec']['forProvider']['manifest'] for o in rendered if o['spec']['forProvider']['manifest']['kind']=='Cluster')
        assert 'initdb' not in manifest['spec']['bootstrap']
        assert not any(p['name']=='barman-cloud.cloudnative-pg.io' for p in manifest['spec'].get('plugins',[]))
        apply(manifest)
        wait(lambda: ready(name), 'Recovery ready: ' + mode)
        result = sql(name, "SELECT string_agg(id::text || ':' || value, ',' ORDER BY id) FROM recovery_proof;")
        expected = '1:after,2:new' if mode == 'latest' else '1:before'
        assert result == expected, (mode, result, expected)
        assert sql(name, 'SELECT pg_is_in_recovery();') == 'f'
        PROOF['restores'][mode] = {'value': result, 'expected': expected, 'ready': True}
    assert sql('seeded', "SELECT string_agg(id::text || ':' || value, ',' ORDER BY id) FROM recovery_proof;") == '1:after,2:new'
    PROOF['base_backup'] = {'id':backup_id,'startedAt':done['status'].get('startedAt'),'stoppedAt':done['status'].get('stoppedAt')}
    PROOF['time_target'] = target_time
    PROOF['source_intact'] = True
    PROOF['images'] = json.loads(kube('get','pods','-A','-o','json'))
    PROOF['images'] = sorted({c['image'] for p in PROOF['images']['items'] for c in p['spec']['containers']})
    PROOF['passed'] = True
finally:
    PROOF['completed'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    (EVIDENCE / 'evidence.json').write_text(json.dumps(PROOF, indent=2)+'\n')
    for kind in ['clusters.postgresql.cnpg.io','backups.postgresql.cnpg.io','objectstores.barmancloud.cnpg.io','pods','events']:
        try:
            (EVIDENCE / (kind+'.yaml')).write_text(kube('-n',NS,'get',kind,'-o','yaml'))
        except Exception:
            pass
