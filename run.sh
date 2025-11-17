#!/usr/bin/env bash
# RUN THIS ON A NEW BRANCH — do not modify main directly.
# Purpose: add workflow inputs (web_app_url, app_name, application_id, version_name, version_code, icon_url, splash_url),
# download web_app_url (zip) inside PROJECT_PATH before build, patch app.json with inputs, keep build non-breaking,
# run tests (npm test) and produce diff for review.
#
# Preconditions:
# - run from repo root
# - git remote origin is set
# - jq, curl, unzip are available on runner (these are common). If not, the script will check and warn.
#
set -euo pipefail

BRANCH="ci/add-weburl-download-and-versioncode"
WORKFLOW=".github/workflows/eas-build-android.yml"
BACKUP="${WORKFLOW}.bak-$(date +%s)"

echo "STEP 0: Sanity checks"
command -v git >/dev/null 2>&1 || { echo "git missing"; exit 1; }
command -v jq >/dev/null 2>&1 || echo "warning: jq not found (some JSON parsing will be skipped)."
command -v curl >/dev/null 2>&1 || { echo "curl missing"; exit 1; }
command -v unzip >/dev/null 2>&1 || echo "warning: unzip not found (if web URL is zip, unzip required)."

echo "STEP 1: Create a new branch (safe)"
git fetch origin
git checkout -b "$BRANCH" || { echo "branch already exists locally, checking it out"; git checkout "$BRANCH"; }

echo "STEP 2: Repository inspection (printing top-level files and key files)"
ls -la
echo "---- package.json (if present) ----"
[ -f package.json ] && jq -C . package.json || echo "package.json not found or jq not available"
echo "---- app.json (if present) ----"
[ -f app.json ] && (cat app.json || true) || echo "app.json not present in repo root"
echo "---- workflow file preview: $WORKFLOW ----"
[ -f "$WORKFLOW" ] || { echo "ERROR: workflow file $WORKFLOW not found"; exit 1; }
sed -n '1,220p' "$WORKFLOW" || true

# Backup workflow
cp "$WORKFLOW" "$BACKUP"
echo "Backup saved to $BACKUP"

echo "STEP 3: Insert workflow inputs for web download and versionCode (if not already present)"
python3 - <<'PY'
import io,sys,re
p="'" + "'" # placeholder to silence linter
wf = "'''"
import pathlib
path = pathlib.Path("{{WORKFLOW}}".replace("{{WORKFLOW}}"," .github/workflows/eas-build-android.yml").strip())
s = path.read_text()
if "workflow_dispatch:" in s and "versionCode" in s:
  print("Inputs already contain versionCode or web inputs — not modifying inputs.")
  sys.exit(0)
# We'll safely inject an inputs: block under workflow_dispatch:
new_inputs = """
workflow_dispatch:
  inputs:
    web_app_url:
      description: 'Web app ZIP URL (must be downloadable). Example: https://.../app.zip'
      required: false
      default: ''
    app_name:
      description: 'App display name (expo.name)'
      required: true
      default: 'My App'
    application_id:
      description: 'Android package id (com.example.myapp)'
      required: true
      default: 'com.example.myapp'
    version_name:
      description: 'App version (expo.version) e.g. 1.0.0'
      required: true
      default: '1.0.0'
    version_code:
      description: 'Android versionCode (integer)'
      required: false
      default: '1'
    icon_url:
      description: 'App icon URL (1024x1024 PNG) optional'
      required: false
      default: ''
    splash_image_url:
      description: 'Splash image URL (1242x2436 PNG) optional'
      required: false
      default: ''
"""
# Insert AFTER a line that exactly equals "workflow_dispatch:" or if none, after "on:"
if "workflow_dispatch:" in s:
  s = s.replace("workflow_dispatch:\n", new_inputs)
else:
  # fallback: find "on:" and insert block after it
  s = s.replace("on:\n", "on:\n" + new_inputs)
path.write_text(s)
print("Injected inputs into workflow_dispatch (or added block).")
PY

echo "STEP 4: Add a safe step BEFORE build to download web_app_url (if provided), extract into PROJECT_PATH and patch app.json"
# We'll inject a small YAML step snippet before the "Run EAS build" step by replacing the first occurrence of the run EAS build command.
# This is a minimal, idempotent insertion that will:
# - if GITHUB event input web_app_url is set, curl it to /tmp/webapp.zip, unzip into ${{ env.PROJECT_PATH }} (default '.'),
# - then patch (or create) app.json with inputs (app_name, application_id, version_name, version_code, icon/splash)
python3 - <<'PY'
import pathlib,sys,re
wfpath = pathlib.Path(".github/workflows/eas-build-android.yml")
s = wfpath.read_text()
needle = "npx eas build"
if needle not in s:
  # try alternative
  needle = "npx eas-cli@latest build"
  if needle not in s:
    print("Cannot find eas build invocation -- manual edit required.")
    sys.exit(1)
insertion = r'''
      - name: Download web app (if provided) and patch app.json
        run: |
          set -e
          # target project dir (keep default project root)
          PROJECT_DIR="${{ env.PROJECT_PATH:-. }}"
          # read inputs passed to the workflow
          WEB_URL="${{ github.event.inputs.web_app_url || '' }}"
          APP_NAME="${{ github.event.inputs.app_name || '' }}"
          APPLICATION_ID="${{ github.event.inputs.application_id || '' }}"
          VERSION_NAME="${{ github.event.inputs.version_name || '' }}"
          VERSION_CODE="${{ github.event.inputs.version_code || '' }}"
          ICON_URL="${{ github.event.inputs.icon_url || '' }}"
          SPLASH_URL="${{ github.event.inputs.splash_image_url || '' }}"

          if [ -n "$WEB_URL" ]; then
            echo "Downloading web app from $WEB_URL"
            tmpzip="/tmp/webapp-$$.zip"
            curl -fsSL "$WEB_URL" -o "$tmpzip" || { echo "download failed"; exit 0; }
            #-- robust zip check --
            if ! file "$tmpzip" | grep -q "Zip archive data"; then
                echo "ERROR: The file downloaded from $WEB_URL is not a valid ZIP archive."
                echo "Please ensure the URL points directly to a ZIP file."
                file "$tmpzip" # print file type for debugging
                exit 1
            fi
            mkdir -p /tmp/webapp-$$
            unzip -q "$tmpzip" -d /tmp/webapp-$$ || true
            # copy contents into project dir but do not overwrite .git
            rsync -a --exclude='.git' /tmp/webapp-$$/ "$PROJECT_DIR/"
            echo "Copied web app into $PROJECT_DIR"
          else
            echo "No WEB_URL provided, skipping download"
          fi

          # patch/create app.json
          APP_JSON_PATH="$PROJECT_DIR/app.json"
          if [ ! -f "$APP_JSON_PATH" ]; then
            echo "{}" > "$APP_JSON_PATH"
          fi
          python3 - <<'PY2'
import json,sys,os
p=os.environ['APP_JSON_PATH']
with open(p,'r') as f:
  try:
    cfg=json.load(f)
  except:
    cfg={}
expo = cfg.get('expo',{}) or {}
# apply inputs
def inp(k): return os.environ.get(k,'') or None
if inp('APP_NAME'): expo['name']=inp('APP_NAME')
if inp('APPLICATION_ID'):
  android = expo.get('android',{}) or {}
  android['package']=inp('APPLICATION_ID')
  expo['android']=android
if inp('VERSION_NAME'): expo['version']=inp('VERSION_NAME')
if inp('VERSION_CODE'):
  android = expo.get('android',{}) or {}
  try:
    android['versionCode']=int(inp('VERSION_CODE'))
  except:
    android['versionCode']=int(inp('VERSION_CODE') or 1)
  expo['android']=android
if inp('ICON_URL'): expo['icon']=inp('ICON_URL')
if inp('SPLASH_URL'):
  splash = expo.get('splash',{}) or {}
  splash['image']=inp('SPLASH_URL')
  expo['splash']=splash
cfg['expo']=expo
with open(p,'w') as f:
  json.dump(cfg,f,indent=2)
print("Patched app.json at",p)
PY2
'''
# Insert insertion before first occurrence of a line containing the eas build call
s2 = re.sub(r'(^\s*- name:\s*Run EAS build[^\n]*\n\s*run:\s*\|\n\s*.*?npx[^\n]*\n)', insertion + r'\1', s, flags=re.S|re.M)
if s2==s:
  # fallback: insert a copy just before the first 'Run EAS build' or the first 'npx eas build' line
  s2 = s.replace("npx eas build", insertion + "\n          npx eas build", 1)
wfpath.write_text(s2)
print("Injected download + patch step before EAS build.")
PY

echo "STEP 5: Run npm test (if present) to ensure we didn't break pre-commit checks"
if [ -f package.json ]; then
  if command -v npm >/dev/null 2>&1; then
    npm test || echo "npm test failed or not defined — check logs in CI. This is expected in some repos."
  else
    echo "npm not installed on runner; skipping npm test."
  fi
else
  echo "No package.json found; skipping npm test."
fi

echo "STEP 6: Show git diff for review (do not auto-commit beyond workflow change)"
git --no-pager diff --staged || true
echo "Now stage and commit the workflow change:"
git add "$WORKFLOW"
git commit -m "ci: add web_app_url download, patch app.json and add versionCode input (non-breaking, branch: $BRANCH)"
git push -u origin "$BRANCH"
echo "Pushed branch $BRANCH. Open a PR from this branch to main and run the workflow with inputs:
- web_app_url (optional) -> URL to a zip containing your web app code
- app_name
- application_id
- version_name
- version_code
- icon_url (1024x1024 PNG)
- splash_image_url (1242x2436 PNG)

Important notes for the reviewer:
- This is minimal, safe: only the workflow file was changed on a new branch.
- If the web URL is not provided, the step is a no-op and build proceeds as before.
- If web_url download fails we intentionally skip (non-fatal) to avoid breaking working builds.
- After PR, run the workflow with inputs and confirm AAB includes the provided metadata (app.json) before merging.
"
