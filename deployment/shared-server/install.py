"""Install this isolated service on the explicitly authorized Ubuntu host.

No existing container is stopped and no existing Nginx file is overwritten.
Run only after reviewing the supplied domain, certificate path and staging files.
"""
import argparse
import gzip
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import urllib.request

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--root',type=Path,required=True);p.add_argument('--image',required=True)
p.add_argument('--domain',required=True);p.add_argument('--certificate-dir',type=Path,required=True)
args=p.parse_args();root=args.root.resolve()
if not re.fullmatch(r'[a-z0-9][a-z0-9.-]+',args.domain):p.error('Invalid domain')
if not args.certificate_dir.is_absolute() or not str(args.certificate_dir).startswith('/etc/letsencrypt/live/'):
    p.error('Use the explicitly reviewed existing certificate directory')
site=Path('/etc/nginx/conf.d/xinlika-shared.conf')
if site.exists():p.error('Nginx site already exists; preserve it and inspect before updating')
baseline=subprocess.check_output(['docker','ps','--format','{{.ID}} {{.Names}}'],text=True).splitlines()
if subprocess.run(['docker','container','inspect','xinlika-shared'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:
    p.error('Service container exists; preserve it and use a reviewed upgrade')
with gzip.open(root/'image.tar.gz','rb') as image:
    process=subprocess.Popen(['docker','load'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    shutil.copyfileobj(image,process.stdin);process.stdin.close()
    code=process.wait(timeout=120)
    if code:raise RuntimeError('Image import failed')
arch=subprocess.check_output(['docker','image','inspect','--format','{{.Architecture}}',args.image],text=True).strip()
if arch!='amd64':raise RuntimeError('Expected amd64 image on this host')
config=root/'private-config'
subprocess.run(['sudo','-n','install','-d','-m','700','-o','10001','-g','10001',str(config)],check=True)
for name in ('processing.json','voxgate.json','model-api-key'):
    subprocess.run(['sudo','-n','install','-m','600','-o','10001','-g','10001',str(root/'staging'/name),str(config/name)],check=True)
subprocess.run(['docker','volume','create','xinlika-shared-data'],check=True,stdout=subprocess.DEVNULL)
init_script="""import os,shutil
from pathlib import Path
p=Path('/data/voxgate-credentials.json')
if p.exists():raise RuntimeError('Preserve existing ASR credentials; inspect the prior deployment')
shutil.copyfile('/staging/voxgate-credentials.json',p);p.chmod(0o600);os.chown(p,10001,10001);os.chown('/data',10001,10001)
"""
subprocess.run(['docker','run','--rm','--user','0','--entrypoint','python','--mount','type=volume,src=xinlika-shared-data,dst=/data',
                '--mount',f'type=bind,src={root / "staging"},dst=/staging,readonly',args.image,'-c',init_script],check=True)
subprocess.run(['docker','run','-d','--name','xinlika-shared','--init','--restart','unless-stopped','--cpus','1','--memory','768m','--pids-limit','128',
                '--stop-timeout','370','-p','127.0.0.1:18778:18778','--mount','type=volume,src=xinlika-shared-data,dst=/data',
                '--mount',f'type=bind,src={config},dst=/config,readonly','--log-opt','max-size=10m','--log-opt','max-file=3',args.image],check=True,stdout=subprocess.DEVNULL)
for _ in range(100):
    try:
        with urllib.request.urlopen('http://127.0.0.1:18778/health',timeout=1) as response:
            if response.status==200:break
    except OSError:pass
    time.sleep(.2)
else:raise RuntimeError('Service not healthy; inspect only its own container log')
text='''server {
    listen 80;
    listen [::]:80;
    server_name DOMAIN;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name DOMAIN;
    ssl_certificate CERT/fullchain.pem;
    ssl_certificate_key CERT/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 1m;
    client_body_timeout 30s;
    location / {
        proxy_pass http://127.0.0.1:18778;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
        proxy_connect_timeout 5s;
        proxy_read_timeout 360s;
        proxy_send_timeout 360s;
        add_header Cache-Control "no-store" always;
    }
}
'''.replace('DOMAIN',args.domain).replace('CERT',str(args.certificate_dir))
candidate=root/'xinlika-shared.conf';candidate.write_text(text)
subprocess.run(['sudo','-n','install','-m','644',str(candidate),str(site)],check=True)
check=subprocess.run(['sudo','-n','nginx','-t'],capture_output=True,text=True)
if check.returncode:
    subprocess.run(['sudo','-n','rm',str(site)],check=True)
    raise RuntimeError('New site did not pass Nginx validation; removed only the new file, no reload performed')
subprocess.run(['sudo','-n','systemctl','reload','nginx'],check=True)
after=subprocess.check_output(['docker','ps','--format','{{.ID}} {{.Names}}'],text=True).splitlines()
assert set(baseline).issubset(set(after)),'An existing container changed; inspect before continuing'
result={'domain':args.domain,'image':args.image,'architecture':arch,'hardwareControl':False,'tls':'existing reviewed wildcard certificate',
        'nginxConfigurationTestPassed':True,'existingContainersUnchanged':True,'existingContainerCount':len(baseline),
        'apiBinding':'127.0.0.1:18778','memoryLimitMiB':768,'cpuLimit':1}
(root/'deployment-result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
