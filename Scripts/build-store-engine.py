#!/usr/bin/env python3
"""Build the embedded Store bridge and a no-JIT Unicorn interpreter from source."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import plistlib
import sys

root = Path(__file__).resolve().parent.parent
work = root / 'build/StoreEngine'
work.mkdir(parents=True, exist_ok=True)
source = root / 'Vendor/UnicornTCI'

def run(args, **kwargs):
    print(' '.join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), cwd=root, check=True, **kwargs)

apis = re.findall(r'handle, "(uc_[a-z_]+)"', (root/'Vendor/IPATool/internal/sap/unicorn/engine.go').read_text())
libraries = []
for name, sdk, goos, minimum in [('device','iphoneos','ios','17.0'), ('simulator','iphonesimulator','ios','17.0')]:
    destination = work/name
    destination.mkdir(parents=True, exist_ok=True)
    sdkpath = subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'], text=True).strip()
    compiler = subprocess.check_output(['xcrun','--sdk',sdk,'--find','clang'], text=True).strip()
    triple = 'arm64-apple-ios17.0' + ('-simulator' if name=='simulator' else '')
    cmake = destination/'unicorn'
    if '--reuse-interpreter' not in sys.argv or not (cmake/'libunicorn.a').exists():
        run(['cmake','-S',source,'-B',cmake,'-G','Ninja',
             '-DCMAKE_SYSTEM_NAME=iOS',f'-DCMAKE_OSX_SYSROOT={sdkpath}',
             '-DCMAKE_OSX_ARCHITECTURES=arm64',f'-DCMAKE_OSX_DEPLOYMENT_TARGET={minimum}',
             f'-DCMAKE_C_COMPILER={compiler}',f'-DCMAKE_C_FLAGS=-target {triple}',
             '-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY','-DCMAKE_BUILD_TYPE=Release',
             '-DBUILD_SHARED_LIBS=OFF','-DUNICORN_ARCH=aarch64','-DUNICORN_INTERPRETER=ON',
             '-DUNICORN_BUILD_TESTS=OFF','-DUNICORN_INSTALL=OFF'])
        run(['cmake','--build',cmake,'--parallel','6'])
    archive = destination/'libRetoolsStore.a'
    env = os.environ.copy()
    env.update(GOOS=goos,GOARCH='arm64',CGO_ENABLED='1',SDKROOT=sdkpath,
               CC=compiler,CGO_CFLAGS=f'-target {triple} -isysroot {sdkpath}',
               CGO_LDFLAGS=f'-target {triple} -isysroot {sdkpath}',
               GOCACHE=str(work/'go-cache'),GOMODCACHE=str(work/'go-modules'))
    print('Building Go bridge for',name,flush=True)
    subprocess.run(['go','build','-mod=mod','-tags=retools_embedded','-buildmode=c-archive','-trimpath','-ldflags=-s -w','-o',str(archive),'.'],
                   cwd=root/'Runtime/StoreEngine',env=env,check=True)
    combined = destination/'libStoreDownloadEngine.a'
    run(['xcrun','libtool','-static','-o',combined,archive,cmake/'libunicorn.a'])
    framework = destination/'StoreDownloadEngine.framework'
    headers = framework/'Headers'
    headers.mkdir(parents=True,exist_ok=True)
    (headers/'RTStoreEngine.h').write_text('''#ifndef RT_STORE_ENGINE_H
#define RT_STORE_ENGINE_H
#ifdef __cplusplus
extern "C" {
#endif
char *rt_store_request(const char *json);
char *rt_store_progress(void);
void rt_store_cancel(void);
void rt_store_free(char *value);
#ifdef __cplusplus
}
#endif
#endif
''')
    modules = framework/'Modules'
    modules.mkdir(exist_ok=True)
    (modules/'module.modulemap').write_text('framework module StoreDownloadEngine { umbrella header "RTStoreEngine.h" export * }\n')
    shutil.copy2(combined,framework/'StoreDownloadEngine')
    (framework/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='dev.retools.storeengine',CFBundleName='StoreDownloadEngine',CFBundleExecutable='StoreDownloadEngine',CFBundlePackageType='FMWK',CFBundleVersion='1',CFBundleShortVersionString='1.0',MinimumOSVersion='17.0')))
    libraries.extend(['-framework',str(framework)])

output = root/'Vendor/StoreDownloadEngine.xcframework'
temporary = work/'StoreDownloadEngine.xcframework'
if temporary.exists(): shutil.rmtree(temporary)
run(['xcodebuild','-create-xcframework',*libraries,'-output',temporary])
if output.exists(): shutil.rmtree(output)
shutil.move(temporary,output)
(work/'unicorn-symbols.txt').write_text('\n'.join(apis)+'\n')
print('Built',output,flush=True)
