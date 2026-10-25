# N7forkop: NetShift 0.9.6 + standalone Zapret migration (preview)

**Status: draft/migration tooling, not a validated live cutover.**
No script in this change installs Forkop, removes NetShift, restarts sing-box,
changes DNS, manipulates nftables, or enables Zapret.

## Router scenario being targeted

- NanoPi R76S, OpenWrt 24.10.4, ARM64.
- NetShift 0.9.6, stock sing-box 1.12.22, separate Zapret package/service.
- Standalone Zapret uses **one** nfqws with several --new blocks:
  Google/YouTube TLS, general TLS and QUIC, Discord voice/STUN UDP, Discord
  discord.media HTTPS on auxiliary ports.
- Legacy Zapret owns NFQUEUE 200; Forkop's managed queues start at 4000.
  Even different queue IDs do **not** make concurrent packet processing safe.

The real NetShift config uses 13 source IP exclusions and a long Sweden
user_domains_text list, on both br-lan and NanoPiWG ingress interfaces. The
router_config tool read all 685 lines with redaction; live credentials were
never exported.

The new n7_source_bypass section is the *first active rule*. It carries the
existing source IP exclusions in fully_routed_ips; Forkop's nft source
fast-path bypasses sing-box for real destinations, keeps FakeIP intercepted,
and its sing-box generator inserts an early source_ip_cidr direct rule and
source-aware DNS. This is only a **proposed behavioral mapping**: changes in
DNS answers or the interaction with standalone Zapret and routed VPN
interfaces still require hands-on testing before installation.

Unsupported source values (IPv6, invalid, broad prefixes below /24), and
name collisions, block rendering rather than dropping affected devices.

No private server URLs, UUIDs, client secrets, device IP lists, or live
NFQWS_OPT from the router are committed to this public repository.

## What the converter handles

It uses the **existing upstream Forkop legacy Podkop converter** after
normalizing NetShift-specific differences:

- Direct proxy_string and selector/urltest text lists, including NetShift's implicit proxy_config_type=url default.
- Multiple subscription_url entries; user agent is converted into individual
  Forkop child subscription entries.
- VPN interface sections, subnets, communities and fully_routed_ips.
- user_domains and user_domains_text -> domain_suffix (real NetShift suffix semantics),
  and user_subnets/user_subnets_text -> Forkop ip_cidr, honoring
  user_domain_list_type/user_subnet_list_type active modes.
  An inactive mode is not silently imported. Multi-line entries,
  commas, whitespace and inline // comments are supported.
- Global DNS over selected proxy -> dns_detour_enabled and section.
- dns_server and bootstrap_dns_server are converted into UCI lists.
- Optional /opt/zapret/config NFQWS_OPT is copied **as a whole**, WITHOUT
  sourcing/evaluating that shell file, into draft n7_zapret_media and
  n7_zapret_voice sections. Both remain **disabled by default**.

The media section selects YouTube/Discord community rules and discord.media.
Voice includes an extra port-based capture rule, but it **may not perfectly
reproduce** standalone Zapret's wide NAT/nft packet selection. In particular,
UDP/STUN endpoints, QUIC and FakeIP interactions must be measured on the
actual router **before switching**.

The converter refuses to render when it finds important unsupported options
such as invalid source-IP exclusions, global_proxy, enabled IPv6 routing,
DoH blocking, unsupported section/connection types, or risky shell syntax in
a standalone Zapret strategy. See the plan JSON for the exact blocker.

## Prepare preview without affecting live traffic

Use a checkout of **Nigh7man/N7forkop** on the router, NOT an installation
script. In that checkout:

~~~sh
sh tools/n7forkop-stage-netshift.sh
~~~

This creates a private /root/n7forkop-netshift-* directory containing
plan.json, a parsed UCI draft forkop, the source netshift.original,
zapret.original and a root-only archive of Zapret files if present,
the original nft ruleset, and a system configuration backup.
All files are root-only and can contain **VPN subscription credentials**.
Never post them publicly.

The ucode entrypoint also supports:

~~~sh
ucode -L forkop/files/usr/lib forkop/files/usr/lib/config/netshift_migration.uc plan
ucode -L forkop/files/usr/lib forkop/files/usr/lib/config/netshift_migration.uc render
~~~

plan reports section counts and blockers WITHOUT printing credentials.
render emits the full candidate including secret URLs, so redirect output
only into a root-private local file. **Do not redirect directly into
/etc/config/forkop** before the cutover has been reviewed.

## Actual cutover is a separate operation

Preconditions:

1. Save an externally accessible full OpenWrt backup and keep a local LAN/SSH
   recovery connection. Verify WAN, DNS, N7 and access to the router work.
2. Compare all draft sections (including FakeIP, direct devices, community
   lists, VPN interface routing, DNS) with the actual NetShift config. Do not
   proceed while plan.json has blockers.
3. Independently check the live Zapret list files referenced by NFQWS_OPT
   and the original nft rules; stage retains those files in place.
4. Select a maintenance window. Two router policy engines must **not** run
   simultaneously; stop standalone Zapret **before enabling** managed Zapret
   actions. NetShift and Forkop must not simultaneously own sing-box/dnsmasq.
5. Test direct internet, YouTube (video and QUIC), Discord login/voice,
   VPN-only domains, source-IP exclusions, DNS and reboots before considering
   the migration complete.
6. If a test fails, disable the new actions, restore NetShift+standalone
   Zapret from the saved backup, and confirm DNS, routing and N7 connectivity.

**No unattended install, auto-enable, or auto-removal is implemented here.**
Rollback automation will only be added after a verified end-to-end switch
procedure exists, to avoid a failed rollback locking the user out of NanoPi.

## Tests

Synthetic fixtures in tests/ contain only non-routable example addresses
and fake proxy URLs:

~~~sh
bash tests/netshift_migration.sh
~~~

This test checks the in-memory migration, preserved strategies, disabled new
sections, DNS, subscriptions/VPN and fail-closed unsupported options.

The independent source-bypass regression test generates actual sing-box
config plus mocked nftables commands, verifying that first-priority
source-address bypass rules precede VPN capture, and that FakeIP is *not*
sent out unmodified:

~~~sh
bash tests/netshift_source_bypass.sh
~~~

This test cannot prove behavior on a live network, particularly when
the original standalone Zapret, the router's wireguard interface or
unusual DNS clients are involved.
For an OpenWrt-specific smoke test, render fixture configuration and verify
that UCI parses it in an isolated temporary directory. Both workflows leave
the running router unchanged.
