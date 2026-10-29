#!/usr/bin/env bash
set -euo pipefail

# This test creates fixture files and captures nft commands using a mock.
# It NEVER changes host nftables, DNS, or any router config.
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
GEN="$LIB/singbox/generator.uc"
NFT="$LIB/nft/apply.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/test.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": "9.9.9.9",
    "source_network_interfaces": ["br-lan", "NanoPiWG"]
  },
  "section": [
    {
      ".name": "n7_source_bypass",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "fully_routed_ips": ["192.0.2.65", "192.0.2.21/32", "192.0.2.22"]
    },
    {
      ".name": "n7_zapret_media",
      ".type": "section",
      "enabled": "0",
      "action": "zapret",
      "domain_suffix": ["youtube.com"]
    },
    {
      ".name": "proxy_after_bypass",
      ".type": "section",
      "enabled": "1",
      "action": "outbound",
      "outbound_json": "{\"type\":\"direct\"}",
      "fully_routed_ips": ["192.0.2.65"],
      "domain_suffix": ["video.example.org"]
    }
  ]
}
JSON

ucode -L "$LIB" "$GEN" generate-config-fixture \
  "$WORK_DIR/test.json" "$WORK_DIR/singbox.json" 127.0.0.1 0 0

node - "$WORK_DIR/singbox.json" <<'NODE'
const assert=require('node:assert/strict');
const fs=require('node:fs');
const config=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const routes=config.route.rules;
const sourceDnsIn=config.inbounds.find(x=>x.tag==='source-dns-in');
assert.ok(sourceDnsIn && sourceDnsIn.listen_port===1603,
  'source-filtered DNS requires the redirected port 1603');
const sourceHijackAt=routes.findIndex(r=>
  r.action==='hijack-dns' && r.inbound==='source-dns-in');
assert.ok(sourceHijackAt>=0,
  'source-dns-in must unconditionally hijack DNS before falling back to direct-out');
assert.ok(sourceHijackAt>routes.findIndex(r=>r.action==='sniff'),
  'DNS sniff must precede source inbound hijack');
assert.ok(sourceHijackAt<routes.findIndex(r=>r.action==='hijack-dns' && r.port===53),
  'the source DNS inbound must be hijacked regardless of the redirected destination port');
assert.ok(sourceHijackAt<routes.findIndex(r=>r.action==='hijack-dns' && r.protocol==='dns'),
  'the source DNS inbound must be hijacked even when TCP DNS sniffing fails');
const outbounds=new Map(config.outbounds.map(x=>[x.tag,x]));
const source=routes.map((r,i)=>[r,i]).find(([r])=>
  Array.isArray(r.source_ip_cidr) && r.source_ip_cidr.length===3);
assert.ok(source, 'missing source IP exclusions route');
assert.equal(source[0].outbound,'bypass-out');
assert.equal(outbounds.get(source[0].outbound).type,'direct');
const vpnRules=routes.map((r,i)=>[r,i]).filter(([r]) =>
  r.outbound==='proxy_after_bypass-out' &&
  (r.source_ip_cidr || r.domain_suffix));
assert.ok(vpnRules.length>0,'missing follow-on VPN routes');
assert.ok(vpnRules.every(([r,i])=>i>source[1]),
  'excluded source must be routed before proxy rules');
const sourceDns=config.dns.rules.filter(r=>Array.isArray(r.source_ip_cidr)
  && r.source_ip_cidr.length===3);
assert.ok(sourceDns.length>0,'missing source-aware DNS');
assert.ok(config.dns.rules.some(r=>r.type==='logical' && r.mode==='and' &&
  r.server==='dnsmasq-server'), 'missing source-aware bypass DNS logic');
console.log('NetShift source exclusions: sing-box route and DNS priority PASS');
NODE

mkdir "$WORK_DIR/mock"
cat > "$WORK_DIR/mock/nft" <<'NFT_MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$NFT_LOG"
exit 0
NFT_MOCK
chmod 0755 "$WORK_DIR/mock/nft"
export NFT_LOG="$WORK_DIR/nft.txt"
export PATH="$WORK_DIR/mock:$PATH"
: > "$NFT_LOG"
ucode -L "$LIB" "$NFT" nft-add-section-priority-rules-fixture \
  "$WORK_DIR/test.json" ForkopTable forkop_interfaces localv4 localv6 0x04000000

node - "$NFT_LOG" <<'NODE'
const assert=require('node:assert/strict');
const fs=require('node:fs');
const lines=fs.readFileSync(process.argv[2],'utf8').split('\n');
const rules=lines.filter(x=>x.startsWith('add rule inet ForkopTable priority_rules '));
const source=rules.find(x=>x.includes('ip saddr @forkop_rule_n7_source_bypass_fully_sources'));
assert.ok(source,'missing nftables source-IP accept rule');
assert.ok(source.includes('ip daddr != 198.18.0.0/15'),
  'FakeIP must NOT be sent straight to WAN');
assert.ok(source.endsWith('counter accept'),
  'real destinations must bypass the proxy');
const vpn=rules.find(x=>x.includes('ip saddr @forkop_rule_proxy_after_bypass_fully_sources'));
assert.ok(vpn,'missing proxy source capture rule');
assert.ok(rules.indexOf(source)<rules.indexOf(vpn),
  'nft bypass must precede proxy capture');
const sourceSet=lines.find(x=>x.includes('forkop_rule_n7_source_bypass_fully_sources') &&
  x.startsWith('add set inet'));
assert.ok(sourceSet,'missing source-IP nft set');
console.log('NetShift source exclusions: nftables fake-IP guard and order PASS');
NODE
