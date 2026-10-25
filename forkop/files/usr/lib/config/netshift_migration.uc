#!/usr/bin/env ucode
// N7forkop: NetShift 0.9.6 migration PREVIEW. Does not touch live services/configs.
let fs = require("fs");
let uci = require("core.uci");
let legacy = require("config.migration");
function s(v) { return v == null ? "" : "" + v; }
function o(v) { return type(v) == "object" ? v : {}; }
function get(v, key) {
    let x = o(v)[key];
    return type(x) == "array" ? join(" ", x) : s(x);
}
function arr(v, key) {
    let x = o(v)[key];
    return x == null ? [] : (type(x) == "array" ? x : (s(x) == "" ? [] : [ s(x) ]));
}
function yes(v) { return v == "1" || v == "true" || v == "yes"; }
function uniq(input) {
    let output = [], seen = {};
    for (let value in input) {
        value = s(value);
        if (value == "" || seen[value]) continue;
        seen[value] = true;
        push(output, value);
    }
    return output;
}
function lines(value) {
    let out = [];
    for (let item in type(value) == "array" ? value : [ value ]) {
        for (let part in split(s(item), "\n")) {
            part = trim(replace(part, /\r/g, ""));
            if (part != "" && substr(part, 0, 1) != "#") push(out, part);
        }
    }
    return uniq(out);
}
function migrate_list(section, destination, original) {
    let list = lines(section[destination] || "");
    for (let v in lines(section[original] || "")) push(list, v);
    if (length(list) > 0) section[destination] = join("\n", uniq(list));
    delete section[original];
}
function model_from_input(input) {
    let sections = input.section || [];
    if (type(sections) != "array") sections = [ sections ];
    let settings = o(input.settings);
    settings[".name"] = "settings";
    settings[".type"] = "settings";
    return { settings, sections, rules: [], subscription_url: [], section_interface: [], urltest: [] };
}
function fix_settings(model, out) {
    let st = model.settings;
    if (yes(get(st, "enable_ipv6")))
        push(out.blockers, "IPv6 routing is enabled: needs a checked mapping");
    if (yes(get(st, "block_doh")))
        push(out.blockers, "DoH blocking is enabled: needs a checked mapping");
    if (yes(get(st, "enable_output_network_interface")) ||
        yes(get(st, "enable_badwan_interface_monitoring")))
        push(out.blockers, "Custom output/WAN monitoring requires manual mapping");
    if (yes(get(st, "dns_hijack")) || yes(get(st, "block_leaks")) ||
        yes(get(st, "bypass_excluded_ips")))
        push(out.blockers, "Newer DNS/capture/kill-switch settings need separate mapping");
    if (length(arr(st, "routing_excluded_ips")) > 0)
        push(out.blockers, "routing_excluded_ips is nonempty: source/FakeIP bypass must be reviewed");
    if (length(arr(st, "dns_pool_server")) > 0 || length(arr(st, "dns_forward")) > 0)
        push(out.blockers, "DNS pool/zone forwarding is not supported by NetShift 0.9.6 migration");
    if (yes(get(st, "dns_via_outbound"))) {
        st.dns_detour_enabled = "1";
        st.dns_detour_section = get(st, "dns_outbound_section") || "main";
    }
    for (let key in [ "dns_via_outbound", "dns_outbound_section", "enable_ipv6",
        "block_doh", "update_notice", "routing_excluded_ips" ]) delete st[key];
}
function fix_section(section, out) {
    let id = get(section, ".name");
    if (id == "") { push(out.blockers, "unnamed NetShift section"); return; }
    let ct = get(section, "connection_type");
    let pt = get(section, "proxy_config_type");
    if (yes(get(section, "global_proxy")))
        push(out.blockers, "section " + id + ": global_proxy requires a reviewed default route");
    delete section.global_proxy;
    let supported = { proxy:1, vpn:1, exclusion:1, block:1, outbound:1 };
    if (ct != "" && !supported[ct])
        push(out.blockers, "section " + id + ": unsupported connection_type=" + ct);
    let supported_proxy = { url:1, urltest:1, selector:1, subscription:1, selector_text:1,
        urltest_text:1, interface:1, outbound:1 };
    if (pt != "" && !supported_proxy[pt])
        push(out.blockers, "section " + id + ": unsupported proxy_config_type=" + pt);
    // NetShift user_domains are suffix matches, not exact full: matches.
    let suffixes = lines(section.domain_suffix || "");
    for (let v in lines(section.user_domains || "")) push(suffixes, v);
    if (length(suffixes) > 0) section.domain_suffix = uniq(suffixes);
    delete section.user_domains;
    migrate_list(section, "ip_cidr", "user_subnets");
    delete section.user_domain_list_type;
    delete section.user_subnet_list_type;
    if (pt == "selector_text" || pt == "urltest_text") {
        let old_key = pt == "selector_text" ? "selector_proxy_links_text" : "urltest_proxy_links_text";
        let new_key = pt == "selector_text" ? "selector_proxy_links" : "urltest_proxy_links";
        let all = lines(section[old_key]);
        for (let v in arr(section, new_key)) push(all, v);
        section[new_key] = uniq(all);
        section.proxy_config_type = pt == "selector_text" ? "selector" : "urltest";
        delete section[old_key];
    }
    if (pt == "subscription") {
        let urls = arr(section, "subscription_urls");
        let agent = get(section, "subscription_user_agent");
        for (let url in arr(section, "subscription_url")) {
            url = trim(s(url));
            if (url == "") continue;
            if (agent != "" && rindex(url, " | ") < 0) url += " | " + agent;
            push(urls, url);
        }
        section.subscription_urls = uniq(urls);
        delete section.subscription_url;
        delete section.subscription_user_agent;
    }
    if (ct == "proxy" && pt == "url" && get(section, "enabled") != "0" &&
        get(section, "proxy_string") == "")
        push(out.blockers, "section " + id + ": enabled proxy with no link");
    if (yes(get(section, "failover_direct")) || yes(get(section, "enable_udp_over_tcp")))
        push(out.blockers, "section " + id + ": unsupported failover/UDP-over-TCP option");
    for (let key in [ "subscription_filter_include_keywords", "subscription_filter_exclude_keywords",
        "subscription_hwid", "subscription_device_os", "subscription_os_version",
        "subscription_device_model" ])
        if (length(arr(section, key)) > 0)
            push(out.blockers, "section " + id + ": " + key + " must be reviewed");
    if (yes(get(section, "subscription_insecure")) ||
        (get(section, "subscription_format_preference") != "" &&
         get(section, "subscription_format_preference") != "auto"))
        push(out.blockers, "section " + id + ": custom subscription security/format requires review");
    if (yes(get(section, "subscription_group_by_countries")) ||
        get(section, "subscription_group_mode") != "")
        push(out.warnings, "section " + id + ": verify subscription grouping after migration");
}
function parse_zapret_config(content, out) {
    if (trim(s(content)) == "") return "";
    let enabled = false, strategy = "", found = false;
    for (let line in split(s(content), "\n")) {
        line = trim(line);
        if (line == "NFQWS_ENABLE=1") enabled = true;
        let m = match(line, /^NFQWS_OPT="(.*)"$/);
        if (m) { strategy = trim(m[1]); found = true; }
    }
    if (!enabled) { push(out.warnings, "No enabled standalone nfqws found"); return ""; }
    if (!found || strategy == "") {
        push(out.blockers, "Standalone Zapret NFQWS_OPT is missing/has unsupported quoting");
        return "";
    }
    if (index(strategy, "$") >= 0 || index(strategy, sprintf("%c", 96)) >= 0 ||
        index(strategy, "\"") >= 0 || index(strategy, "'") >= 0 ||
        index(strategy, "\\") >= 0 ||
        index(strategy, "--qnum") >= 0 || index(strategy, "--dpi-desync-fwmark") >= 0) {
        push(out.blockers, "Standalone Zapret NFQWS_OPT needs manual syntax review");
        return "";
    }
    return strategy;
}
function add_media_sections(model, config, out) {
    let strategy = parse_zapret_config(config, out);
    if (strategy == "") return;
    let seen = {};
    for (let sec in model.sections) seen[get(sec, ".name")] = true;
    if (seen.n7_zapret_media || seen.n7_zapret_voice) {
        push(out.blockers, "Reserved n7_zapret_* section names already exist");
        return;
    }
    // Keep ALL existing --new groups verbatim. Sections are deliberately disabled.
    let next = [{
        ".name": "n7_zapret_media", ".type": "section", enabled: "0",
        label: "N7 YouTube and Discord - enable only at cutover",
        action: "zapret", community_lists: [ "youtube", "discord" ],
        domain_suffix: [ "discord.media" ], nfqws_opt: strategy
    }];
    if (index(strategy, "--filter-l7=discord,stun") >= 0) {
        push(next, {
            ".name": "n7_zapret_voice", ".type": "section", enabled: "0",
            label: "N7 Discord voice UDP - verify port coverage",
            action: "zapret", ports: "19294-19344,50000-50100",
            nfqws_opt: strategy
        });
        push(out.warnings, "Disabled voice UDP section uses port capture; compare against legacy nft rules");
    }
    for (let sec in model.sections) push(next, sec);
    model.sections = next;
    push(out.warnings, "Zapret sections stay disabled until standalone Zapret is stopped");
    push(out.warnings, "Original nfqws strategy kept, but Forkop packet selection needs live verification");
}
function migrate(input, zapret_content) {
    let out = { blockers: [], warnings: [], model: null, summary: null };
    if (!input || input.settings == null)
        push(out.blockers, "NetShift settings section not found");
    let model = model_from_input(o(input));
    if (length(model.sections) == 0)
        push(out.blockers, "No NetShift sections found");
    fix_settings(model, out);
    for (let section in model.sections) fix_section(section, out);
    add_media_sections(model, zapret_content, out);
    let res = legacy.migrate_model(model, "podkop");
    out.model = res.model;
    let actions = {};
    for (let sec in out.model.sections) {
        let act = get(sec, "action");
        actions[act] = (actions[act] || 0) + 1;
    }
    out.summary = { sections: length(out.model.sections), subscriptions: length(out.model.subscription_url),
        interfaces: length(out.model.section_interface), urltests: length(out.model.urltest),
        actions, zapret_enabled_by_default: false };
    return out;
}
function valid_id(value) { return match(s(value), /^[A-Za-z_][A-Za-z0-9_-]*$/) != null; }
function quote(value) {
    value = replace(s(value), /\\/g, "\\\\");
    value = replace(value, /"/g, "\\\"");
    return "\"" + value + "\"";
}
function emit(section, kind) {
    let name = get(section, ".name");
    if (!valid_id(kind) || (name != "" && !valid_id(name))) {
        warn("Invalid section identifier\n"); exit(1);
    }
    print("config ", kind);
    if (name != "" && substr(name, 0, 2) != "__") print(" ", quote(name));
    print("\n");
    for (let key in keys(section)) {
        if (substr(key, 0, 1) == ".") continue;
        if (!valid_id(key)) { warn("Invalid option identifier\n"); exit(1); }
        let v = section[key];
        if (type(v) == "array") {
            for (let item in v) print("\tlist ", key, " ", quote(item), "\n");
        }
        else if (v != null) print("\toption ", key, " ", quote(v), "\n");
    }
    print("\n");
}
function render(model) {
    print("# N7forkop preview: migrated from NetShift 0.9.6; DO NOT apply without review.\n");
    emit(model.settings, "settings");
    for (let section in model.sections) emit(section, "section");
    for (let kind in [ "subscription_url", "section_interface", "urltest" ])
        for (let child in model[kind] || []) emit(child, kind);
}
function live_input() {
    uci.load("netshift");
    return { settings: uci.get_all("netshift", "settings"),
        section: uci.section_objects("netshift", "section") };
}
function main(argv) {
    let mode = argv[0] || "plan";
    let fixture = index(mode, "fixture-") == 0;
    let input, zapret_content = "";
    if (fixture) {
        if (s(argv[1]) == "") { warn("Fixture filename required\n"); return 2; }
        let data = fs.readfile(argv[1]);
        if (data == null) { warn("Fixture not readable\n"); return 2; }
        input = json(data);
        if (s(argv[2]) != "") zapret_content = s(fs.readfile(argv[2]) || "");
    }
    else {
        input = live_input();
        zapret_content = s(fs.readfile("/opt/zapret/config") || "");
    }
    let result = migrate(input, zapret_content);
    if (mode == "plan" || mode == "fixture-plan") {
        print(sprintf("%J\n", { ok: length(result.blockers) == 0,
            warnings: result.warnings, blockers: result.blockers, summary: result.summary }));
        return length(result.blockers) == 0 ? 0 : 1;
    }
    if (mode == "fixture-json") {
        print(sprintf("%J\n", { ok: length(result.blockers) == 0,
            config: { settings: result.model.settings, section: result.model.sections,
                subscription_url: result.model.subscription_url,
                section_interface: result.model.section_interface, urltest: result.model.urltest },
            warnings: result.warnings, blockers: result.blockers }));
        return 0;
    }
    if (mode == "render" || mode == "fixture-render") {
        if (length(result.blockers) > 0) {
            for (let item in result.blockers) warn("BLOCKED: " + item + "\n");
            return 1;
        }
        render(result.model);
        return 0;
    }
    warn("Usage: netshift_migration.uc <plan|render|fixture-plan|fixture-json|fixture-render> [fixture.json] [zapret.cfg]\n");
    return 2;
}
if (sourcepath(1) != null && sourcepath(1) != "")
    return { migrate, render, parse_zapret_config };
exit(main(ARGV));
