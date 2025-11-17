import json, sys, os

p = os.environ.get('APP_JSON_PATH', './app.json')

with open(p, 'r') as f:
    try:
        cfg = json.load(f)
    except:
        cfg = {}

expo = cfg.get('expo', {}) or {}

def inp(k): return os.environ.get(k, '') or None

if inp('APP_NAME'): expo['name'] = inp('APP_NAME')
if inp('APPLICATION_ID'):
    android = expo.get('android', {}) or {}
    android['package'] = inp('APPLICATION_ID')
    expo['android'] = android
if inp('VERSION_NAME'): expo['version'] = inp('VERSION_NAME')
if inp('VERSION_CODE'):
    android = expo.get('android', {}) or {}
    try:
        android['versionCode'] = int(inp('VERSION_CODE'))
    except:
        android['versionCode'] = int(inp('VERSION_CODE') or 1)
    expo['android'] = android
if inp('ICON_URL'): expo['icon'] = inp('ICON_URL')
if inp('SPLASH_URL'):
    splash = expo.get('splash', {}) or {}
    splash['image'] = inp('SPLASH_URL')
    expo['splash'] = splash

cfg['expo'] = expo

with open(p, 'w') as f:
    json.dump(cfg, f, indent=2)

print('Patched app.json at', p)
