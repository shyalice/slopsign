#!/usr/bin/env python3
"""Package a domain owner's ACME TLS identity for a phone's loopback server.
This script never accepts app signing certificates or IPA files.
"""
import argparse,hashlib,json,os,shutil,subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--host',required=True)
p.add_argument('--fullchain',required=True,type=Path)
p.add_argument('--private-key',required=True,type=Path)
p.add_argument('--public-base',required=True)
p.add_argument('--output',type=Path,default=Path('Server/dist'))
p.add_argument('--bundle-output',type=Path)
a=p.parse_args()
openssl=shutil.which('openssl')
if Path('/opt/homebrew/opt/openssl@3/bin/openssl').exists():openssl='/opt/homebrew/opt/openssl@3/bin/openssl'
subprocess.run([openssl,'x509','-in',str(a.fullchain),'-noout','-checkhost',a.host],check=True)
subprocess.run([openssl,'x509','-in',str(a.fullchain),'-noout','-checkend','0'],check=True)
a.output.mkdir(parents=True,exist_ok=True)
password=os.environ.get('ESIGN_TLS_PACKAGE_PASSWORD','ESignLocalTLS')
package=a.output/'server.p12'
subprocess.run([openssl,'pkcs12','-export','-legacy','-in',str(a.fullchain),'-inkey',str(a.private_key),'-out',str(package),'-passout','env:ESIGN_TLS_PACKAGE_PASSWORD'],env=dict(os.environ,ESIGN_TLS_PACKAGE_PASSWORD=password),check=True,capture_output=True)
config={'host':a.host,'p12URL':a.public_base.rstrip('/')+'/server.p12','password':password,'sha256':hashlib.sha256(package.read_bytes()).hexdigest()}
(a.output/'installation.json').write_text(json.dumps(config,indent=2)+'\n')
if a.bundle_output:
 a.bundle_output.parent.mkdir(parents=True,exist_ok=True)
 shutil.copy2(package,a.bundle_output)
print('Created',a.output/'installation.json','and',package)
