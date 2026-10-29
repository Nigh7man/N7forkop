#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$ROOT" python3 - <<'PY'
import os,json,re
from pathlib import Path
p=Path(os.environ['ROOT'])
menu=json.loads((p/'luci-app-forkop/root/usr/share/luci/menu.d/luci-app-forkop.json').read_text())
assert menu['admin/services/forkop']['title']=='N7Flow'
assert menu['admin/services/forkop']['action']['path']=='forkop/forkop'
ui=(p/'luci-app-forkop/htdocs/luci-static/resources/view/forkop/forkop.js').read_text()
assert '_("N7Flow")' in ui
assert '_("VPN, DNS and traffic routing")' in ui
pofiles=[p/'luci-app-forkop/po/ru/forkop.po',p/'fe-app-forkop/locales/forkop.ru.po']
assert pofiles[0].read_bytes()==pofiles[1].read_bytes()
entries=dict(re.findall(r'^msgid "(.*?)"\nmsgstr "(.*?)"$',pofiles[0].read_text(),re.M))
assert len(entries)>=700
assert not [k for k,v in entries.items() if k and not v]
for key,val in {'N7Flow':'N7Flow','Sections':'Правила','Servers':'Серверы','Dashboard':'Обзор','Monitoring':'Соединения','Components':'Обновления'}.items():
    assert entries[key]==val,(key,entries.get(key))
print(f'N7Flow branding and {len(entries)-1} Russian UI translations: PASS')
PY
