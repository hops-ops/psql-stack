#!/usr/bin/env python3
"""Primary/standby and missing-series contracts for the rendered backup alerts."""
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import yaml

ROOT=Path(__file__).resolve().parents[2]
result=subprocess.run(['up','composition','render','--xrd=apis/psqlclusters/definition.yaml','apis/psqlclusters/composition.yaml','examples/psqlclusters/backups.yaml','--quiet'],cwd=ROOT,text=True,capture_output=True,check=True,timeout=180)
rule=next(d['spec']['forProvider']['manifest'] for d in yaml.safe_load_all(result.stdout) if d and d['kind']=='Object' and d['spec']['forProvider']['manifest']['kind']=='PrometheusRule')
ALERTS=[r['alert'] for g in rule['spec']['groups'] for r in g['rules']]
by_name={r['alert']:r for g in rule['spec']['groups'] for r in g['rules']}
labels={'cnpg_cluster':'app-db','namespace':'databases'}
selector='job="cnpg-backups",namespace="databases",cnpg_cluster="app-db",cnpg_role="primary"'

def series(metric,values,role='primary',extra=''):
    return {'series':metric+'{'+selector.replace('cnpg_role="primary"','cnpg_role="'+role+'"')+extra+'}','values':values}
healthy=[series('up','1+0x80'),series('cnpg_collector_up','1+0x80'),series('barman_cloud_cloudnative_pg_io_last_available_backup_timestamp','1+0x80'),series('barman_cloud_cloudnative_pg_io_last_failed_backup_timestamp','0+0x80'),series('cnpg_collector_pg_wal_archive_status','0+0x80',extra=',value="ready"')]
tests=[]
def scenario(name,inputs,expected,when='40m'):
    assertions=[]
    for alert in ALERTS:
        r=by_name[alert]
        assertions.append({'eval_time':when,'alertname':alert,'exp_alerts':[{'exp_labels':dict(labels,**r['labels']),'exp_annotations':r['annotations']}] if alert in expected else []})
    tests.append({'name':name,'interval':'1m','input_series':inputs,'alert_rule_test':assertions})
scenario('healthy primary',healthy,[])
scenario('all series absent',[],['PostgresBackupMetricsMissing','PostgresBackupNeverCompleted'])
scenario('healthy standby cannot mask missing primary',[dict(s,series=s['series'].replace('cnpg_role="primary"','cnpg_role="replica"')) for s in healthy],['PostgresBackupMetricsMissing','PostgresBackupNeverCompleted'])
scenario('standby queued files never page',healthy+[series('cnpg_collector_pg_wal_archive_status','50+0x80',role='replica',extra=',value="ready"')],[])
scenario('persistent primary backlog',[s for s in healthy if 'archive_status' not in s['series']]+[series('cnpg_collector_pg_wal_archive_status','2+0x80',extra=',value="ready"')],['PostgresWALArchiveBacklog'])
scenario('failed primary scrape',[s for s in healthy if not s['series'].startswith('up{')]+[series('up','0+0x80')],['PostgresBackupMetricsMissing'])
scenario('collector telemetry absent',[s for s in healthy if not s['series'].startswith('cnpg_collector_up{')],['PostgresBackupMetricsMissing'])
scenario('no available backup',[s for s in healthy if 'last_available' not in s['series']],['PostgresBackupNeverCompleted'])
scenario('newer failure',[s for s in healthy if 'last_failed' not in s['series']]+[series('barman_cloud_cloudnative_pg_io_last_failed_backup_timestamp','120+0x80')],['PostgresBackupFailed'])
scenario('initial failure with no success',[s for s in healthy if 'last_available' not in s['series'] and 'last_failed' not in s['series']]+[series('barman_cloud_cloudnative_pg_io_last_failed_backup_timestamp','120+0x80')],['PostgresBackupFailed','PostgresBackupNeverCompleted'])
scenario('brief backlog does not page',[s for s in healthy if 'archive_status' not in s['series']]+[series('cnpg_collector_pg_wal_archive_status','0+0x30 2+0x5 0+0x40',extra=',value="ready"')],[])
# Hold timestamp constant for >30h. Other metrics continue to arrive.
long=[dict(s,values=s['values'].replace('x80','x2000')) for s in healthy]
scenario('backup older than maximum age',long,['PostgresBackupStale'],when='31h')
fixture={'rule_files':['rules.yaml'],'evaluation_interval':'1m','tests':tests}
files={'rules.yaml':yaml.safe_dump({'groups':rule['spec']['groups']}),'tests.yaml':yaml.safe_dump(fixture)}
if os.environ.get('PROMTOOL'):
    with tempfile.TemporaryDirectory() as tmp:
        for name,data in files.items():(Path(tmp)/name).write_text(data)
        subprocess.run([os.environ['PROMTOOL'],'test','rules','tests.yaml'],cwd=tmp,check=True)
else:
    # Stream fixtures so this also works with remote Docker engines.
    buf=io.BytesIO()
    with tarfile.open(fileobj=buf,mode='w') as archive:
        for name,data in files.items():
            encoded=data.encode(); info=tarfile.TarInfo(name);info.size=len(encoded);archive.addfile(info,io.BytesIO(encoded))
    subprocess.run(['docker','run','--rm','-i','--entrypoint','/bin/sh','quay.io/prometheus/prometheus:v3.11.0','-c','cd /tmp && tar xf - && promtool test rules tests.yaml'],input=buf.getvalue(),check=True)
print(f'{len(tests)} backup alert scenarios passed')
