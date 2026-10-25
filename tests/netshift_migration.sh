#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UC="$ROOT_DIR/forkop/files/usr/lib/config/netshift_migration.uc"
LIB="$ROOT_DIR/forkop/files/usr/lib"
F="$ROOT_DIR/tests/netshift06.fixture.json"
Z="$ROOT_DIR/tests/zapret06.fixture.conf"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ucode -c -o /dev/null "$UC"
ucode -L "$LIB" "$UC" fixture-json "$F" "$Z" >"$TMP/result.json"
node - "$TMP/result.json" "$Z" <<'NODE'
const fs=require('node:fs');
const assert=require('node:assert/strict');
const {config,warnings,blockers,ok}=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const z=fs.readFileSync(process.argv[3],'utf8').match(/^NFQWS_OPT="(.*)"$/m)[1];
assert.equal(ok,true);
assert.deepEqual(blockers,[]);
assert.equal(config.settings.dns_detour_enabled,'1');
assert.equal(config.settings.dns_detour_section,'main');
assert.deepEqual(config.settings.dns_server,['77.88.8.8']);
assert.equal('enable_ipv6' in config.settings,false);
assert.equal('block_doh' in config.settings,false);
const sections=Object.fromEntries(config.section.map(s=>[s['.name'],s]));
assert.equal(sections.n7_zapret_media.enabled,'0');
assert.equal(sections.n7_zapret_voice.enabled,'0');
assert.equal(sections.n7_zapret_media.action,'zapret');
assert.deepEqual(sections.n7_zapret_media.community_lists,['youtube','discord']);
assert.equal(sections.n7_zapret_media.nfqws_opt,z);
assert.equal(sections.n7_zapret_voice.nfqws_opt,z);
assert.ok(sections.n7_zapret_voice.ports.includes('19294-19344'));
assert.equal(config.section[0]['.name'],'n7_zapret_media');
assert.equal(sections.main.action,'connection');
assert.deepEqual(sections.main.selector_proxy_links,['vless://example.invalid:443?encryption=none#example']);
assert.ok(sections.main.domain.includes('google_ai.example'));
assert.ok(!sections.main.domain.includes('full:google_ai.example'),'NetShift domains must stay suffix matches');
assert.ok(sections.main.ip_cidr.includes('203.0.113.4/32'));
assert.equal('user_domains' in sections.main,false);
assert.equal('global_proxy' in sections.main,false);
assert.deepEqual(sections.selector.selector_proxy_links,['vless://one','vless://two']);
assert.deepEqual(sections.urltest.selector_proxy_links,['trojan://one','ss://two']);
assert.equal(config.subscription_url.length,2);
assert.deepEqual(config.subscription_url.map(s=>s.url).sort(),[
  'https://example.invalid/feed2?a=2','https://example.invalid/feed?a=1'
]);
assert.ok(config.subscription_url.every(s=>s.user_agent==='ExampleClient/1.0'));
assert.equal(config.section_interface.length,1);
assert.equal(config.section_interface[0].name,'awg0');
assert.equal(sections.direct.action,'bypass');
assert.ok(warnings.some(s=>s.includes('DISABLED')||s.includes('disabled')));
console.log('NetShift fixture conversion: PASS');
NODE

# A safe preview must be parseable by UCI. The router itself is NEVER touched.
ucode -L "$LIB" "$UC" fixture-render "$F" "$Z" >"$TMP/forkop"
if command -v uci >/dev/null 2>&1; then
  uci -c "$TMP" -q show forkop > "$TMP/roundtrip"
  grep -q "forkop.n7_zapret_media.enabled='0'" "$TMP/roundtrip"
  grep -q 'forkop.subscriptions.action=' "$TMP/roundtrip"
fi

node - "$F" "$TMP/bad.json" <<'NODE'
const fs=require('node:fs');
const p=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
p.settings.routing_excluded_ips=['192.168.78.17'];
p.section[0].global_proxy='1';
fs.writeFileSync(process.argv[3],JSON.stringify(p));
NODE
if ucode -L "$LIB" "$UC" fixture-plan "$TMP/bad.json" "$Z" > "$TMP/blocked.json"; then
  echo 'FAIL: unsupported source bypass/global proxy should have blocked preview' >&2
  exit 1
fi
node - "$TMP/blocked.json" <<'NODE'
const assert=require('node:assert/strict');
const r=JSON.parse(require('node:fs').readFileSync(process.argv[2],'utf8'));
assert.equal(r.ok,false);
assert.ok(r.blockers.some(x=>x.includes('routing_excluded_ips')));
assert.ok(r.blockers.some(x=>x.includes('global_proxy')));
assert.equal(JSON.stringify(r).includes('vless://'),false,'plan must not expose server secrets');
console.log('Blocking checks and safe diagnostic: PASS');
NODE
if ucode -L "$LIB" "$UC" fixture-render "$TMP/bad.json" "$Z" > "$TMP/no-output" 2>/dev/null; then
  echo 'FAIL: renderer emitted unsupported config' >&2
  exit 1
fi
[ ! -s "$TMP/no-output" ] || { echo 'FAIL: renderer leaked partial draft' >&2; exit 1; }
printf '%s\n' 'NetShift migration unit tests passed'
