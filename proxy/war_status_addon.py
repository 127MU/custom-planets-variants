"""Narrow mitmproxy addon. Never persists HTTP bodies, credentials or account IDs."""
import json
import os
import re
import copy
import time
import hashlib
import asyncio
import urllib.request
import math
from pathlib import Path

HOST = "api.live.prod.thehelldiversgame.com"
STATUS = re.compile(r"^/api/WarSeason/[0-9]+/Status$")
WAR_INFO = re.compile(r"^/api/WarSeason/[0-9]+/WarInfo$")
INVENTORY = "/api/Progression/inventory"
ITEM_CATALOG = "/api/Progression/items"
ARMORY_ENDPOINTS = {INVENTORY.lower(): "inventory", ITEM_CATALOG.lower(): "item_catalog"}
STRATAGEM_LICENSE_CATEGORY = 11
WEAPON_TEMPLATES = {0x7DE53646: 0xE673DCC8, 0x7349AF9A: 0x7C816371, 0xC9F609BA: 0xA7977F98}
DEFAULT_WEAPON_TEMPLATES = {"primary": 0xAA035309, "secondary": 0xA7977F98, "throwable": 0xBE376EA8}
MAX_BODY = 8 * 1024 * 1024
# Verified type40 tag/type71 presence pairs, war 801. Never infer by ID adjacency.
EFFECT_PAIRS = ((1202,1203),(1243,1245),(1244,1386),(1248,1249),(1303,1310),
                (1306,1309),(1307,1308),(1360,1361),(1377,1378),(1380,1379),
                (1401,1400),(1402,1403),(1413,1414))
# Verified native bots_cyborgs presence. Only use ORIGINAL server effects to
# infer a liberated planet's enemy; user-added cross-faction effects don't count.
NATIVE_ENEMY_EFFECTS = {1361: 3}


class InventorySchemaError(ValueError):
    pass


def weapon_series(model):
    match = re.match(r"^([A-Z0-9/]+)-(\d+)", model.upper())
    return match.groups() if match else ("", "")


def rewrite_weapon_catalog(document, plan, weapons):
    """Use only original live rows as templates for selected armory items."""
    manual = plan.get("items")
    if not isinstance(manual, list) or len(manual) > 128:
        return document, 0
    selected = set(weapons) if plan.get("unlockAllWeapons") is True else {
        row["mixId"] for row in manual if isinstance(row, dict)
        and type(row.get("mixId")) is int and row["mixId"] in weapons}
    if not selected:
        return document, 0
    if not isinstance(document, list) or not all(isinstance(row, dict) for row in document):
        raise InventorySchemaError()
    existing = {row[key] for row in document for key in ("itemId", "mixId") if type(row.get(key)) is int}
    templates = {}
    for row in document:
        item_id = row.get("itemId")
        if type(item_id) is int and item_id in weapons and row.get("mixId") == item_id:
            kind, model = weapons[item_id]
            templates.setdefault(kind, []).append((item_id, weapon_series(model), row))

    added = []
    missing = 0
    for item_id in sorted(selected - existing):
        kind, model = weapons[item_id]
        candidates = templates.get(kind)
        if not candidates:
            missing += 1
            continue
        series = weapon_series(model)
        preferred = WEAPON_TEMPLATES.get(item_id)
        _, _, template = max(candidates, key=lambda candidate: (
            candidate[0] == preferred,
            bool(series[0]) and candidate[1] == series,
            bool(series[0]) and candidate[1][0] == series[0],
            candidate[0] == DEFAULT_WEAPON_TEMPLATES[kind],
            -candidate[0],
        ))
        added.append({**template, "itemId": item_id, "mixId": item_id})
    return ([*document, *added] if added else document), missing


def stratagem_licenses(document):
    """Return only license IDs advertised by the original item catalog."""
    if not isinstance(document, list) or not all(isinstance(row, dict) for row in document):
        return ()
    return tuple(sorted({
        row["mixId"] for row in document
        if row.get("progressionCategory") == STRATAGEM_LICENSE_CATEGORY
        and row.get("isConsumable") is False
        and type(row.get("mixId")) is int and 0 < row["mixId"] <= 0xFFFFFFFF
    }))


def rewrite_inventory(document, plan, weapon_ids=(), stratagem_ids=()):
    """Apply a local preview without changing requests or upstream state."""
    def uint(value):
        return type(value) is int and 0 <= value <= 0xFFFFFFFF

    if not isinstance(plan, dict) or plan.get("enabled") is not True:
        return document
    if not isinstance(document, dict):
        raise InventorySchemaError()
    unlock_all = plan.get("unlockAllWeapons", False)
    unlock_stratagems = plan.get("unlockAllStratagems", False)
    if type(unlock_all) is not bool or type(unlock_stratagems) is not bool:
        return document
    items, customized = document.get("items"), document.get("customization")
    added, overrides = (plan.get(key) for key in ("items", "customization"))
    if not all(isinstance(rows, list) and len(rows) <= 128 for rows in (added, overrides)):
        return document
    if not isinstance(items, list) or not all(isinstance(row, dict) and uint(row.get("mixId")) for row in items):
        raise InventorySchemaError()
    if not all(isinstance(row, dict) and uint(row.get("mixId")) and row["mixId"]
               and type(row.get("amount")) is int and row["amount"] == 1
               and type(row.get("isDiscovered")) is bool for row in added):
        return document
    fields = ("mixId32", "index", "activeIndex", "slots", "modes")
    for row in overrides:
        if not isinstance(row, dict) or not all(uint(row.get(key)) for key in fields[:3]) or not row["mixId32"]:
            return document
        for key, length in (("slots", 8), ("modes", 4)):
            values = row.get(key)
            if not isinstance(values, list) or len(values) != length or not all(map(uint, values)):
                return document
    changes = plan.get("attachmentChanges", [])
    if not isinstance(changes, list) or len(changes) > 128:
        return document
    swaps = {}
    for row in changes:
        if not isinstance(row, dict) or not all(uint(row.get(key)) and row[key]
                for key in ("weapon", "from", "to")) or row["from"] == row["to"]:
            return document
        swaps.setdefault(row["weapon"], {})[row["from"]] = row["to"]
    result_items = list(items)
    owned = {row["mixId"] for row in result_items}
    for row in added:
        mix_id = row["mixId"]
        if mix_id not in owned:
            result_items.append({key: row[key] for key in ("mixId", "amount", "isDiscovered")})
            owned.add(mix_id)
    for active, ids in ((unlock_all, weapon_ids), (unlock_stratagems, stratagem_ids)):
        if not active:
            continue
        for mix_id in ids:
            if uint(mix_id) and mix_id and mix_id not in owned:
                result_items.append({"mixId": mix_id, "amount": 1, "isDiscovered": False})
                owned.add(mix_id)
    if not overrides and not swaps:
        return {**document, "items": result_items} if result_items != items else document
    if not isinstance(customized, list) or not all(
            isinstance(row, dict) and uint(row.get("mixId32")) and uint(row.get("index"))
            for row in customized):
        raise InventorySchemaError()
    replacements = {(row["mixId32"], row["index"]): {key: row[key] for key in fields}
                    for row in overrides}
    result_customized = []
    for row in customized:
        replacement = replacements.pop((row["mixId32"], row["index"]), None)
        result_customized.append({**row, **replacement} if replacement else row)
    result_customized.extend(replacements.values())
    for index, row in enumerate(result_customized):
        by_option = swaps.get(row["mixId32"])
        slots = row.get("slots")
        if by_option and isinstance(slots, list) and len(slots) == 8 and all(map(uint, slots)):
            # Match actual option IDs, never treat a data-table slot enum as an array index.
            result_customized[index] = {**row, "slots": [by_option.get(value, value) for value in slots]}
    if result_items == items and result_customized == customized:
        return document
    return {**document, "items": result_items, "customization": result_customized}


class ApiOnlyRouter:
    """Loopback CONNECT dispatcher. Only the exact game API enters mitmproxy.

    All other TLS connections retain end-to-end encryption and connect directly;
    their headers, bodies and destination names are never persisted.
    """
    def __init__(self, api_port):
        import socket
        import socketserver
        import select
        from threading import Thread
        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                upstream = None
                established = False
                try:
                    self.request.settimeout(10)
                    header = bytearray()
                    while b"\r\n\r\n" not in header:
                        part = self.request.recv(1)
                        if not part:
                            return
                        header.extend(part)
                        if len(header) > 16384:
                            return
                    first = bytes(header).split(b"\r\n", 1)[0].decode("ascii")
                    method, destination, version = first.split(" ")
                    if method == "CONNECT":
                        host, port = destination.rsplit(":", 1)
                        host = host.removeprefix("[").removesuffix("]")
                        port = int(port)
                    else:
                        from urllib.parse import urlsplit
                        url = urlsplit(destination)
                        if url.scheme != "http" or not url.hostname or url.username or url.password:
                            raise ValueError("absolute HTTP URL required")
                        host, port = url.hostname, url.port or 80
                    if not host or not 1 <= port <= 65535:
                        return
                    is_api = method == "CONNECT" and host.lower() == HOST and port == 443
                    upstream = socket.create_connection(("127.0.0.1", api_port) if is_api else (host, port), timeout=10)
                    if is_api:
                        # Rebuild the public CONNECT line only; don't forward
                        # Proxy-Authorization or unrelated client headers.
                        upstream.sendall(("CONNECT " + HOST + ":443 HTTP/1.1\r\nHost: " + HOST + ":443\r\n\r\n").encode("ascii"))
                    elif method == "CONNECT":
                        self.request.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
                    else:
                        # Anti-cheat/update clients may use plain HTTP. Send
                        # origin-form requests directly, not through mitmproxy.
                        path = (url.path or "/") + ("?" + url.query if url.query else "")
                        lines = bytes(header).split(b"\r\n")[1:]
                        lines = [line for line in lines if line and not line.lower().startswith((b"proxy-authorization:", b"proxy-connection:", b"connection:"))]
                        upstream.sendall((method + " " + path + " " + version + "\r\n").encode("ascii") + b"\r\n".join(lines) + b"\r\nConnection: close\r\n\r\n")
                    established = True
                    self.request.settimeout(15);upstream.settimeout(15)
                    while True:
                        readable, _, _ = select.select([self.request, upstream], [], [], 300)
                        if not readable:
                            return
                        for source in readable:
                            chunk = source.recv(65536)
                            if not chunk:
                                return
                            (upstream if source is self.request else self.request).sendall(chunk)
                except (OSError, ValueError, UnicodeError):
                    if not established:
                        try:
                            self.request.sendall(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
                        except OSError:
                            pass
                    return
                finally:
                    if upstream:
                        upstream.close()
        class Server(socketserver.ThreadingTCPServer):
            daemon_threads = True
            allow_reuse_address = False
        self.server = Server(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        self.thread = Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown();self.server.server_close();self.thread.join(timeout=2)


class LocalRevocationService:
    """Serve only this session's CA-signed CRL on loopback, never files."""
    def __init__(self, certstore):
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        from threading import Thread
        from cryptography import x509
        crl = certstore.default_crl

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path != "/ca.crl":
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/pkix-crl")
                self.send_header("Content-Length", str(len(crl)))
                self.end_headers()
                self.wfile.write(crl)

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.url = "http://127.0.0.1:%s/ca.crl" % self.server.server_port
        try:
            entry = certstore.get_cert(HOST, [x509.DNSName(HOST)], crl_url=self.url)
            certstore.add_cert(entry, HOST)
            self.certificate = entry.cert.to_pem()
            self.thread = Thread(target=self.server.serve_forever, daemon=True)
            self.thread.start()
        except BaseException:
            self.server.server_close()
            raise

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


def normalize_targets(plan):
    if plan.get("schema", 2) != 2:
        raise ValueError("不支持的方案版本")
    targets = plan.get("targets")
    if not isinstance(targets, list) or len(targets) > 64:
        raise ValueError("方案最多包含 64 颗星球")
    result, seen = [], set()
    for raw in targets:
        if not isinstance(raw, dict):
            raise ValueError("星球配置无效")
        if type(raw.get("enabled", True)) is not bool:
            raise ValueError("星球开关必须是布尔值")
        if raw.get("enabled", True) is False:
            continue
        planet = raw.get("planet")
        if type(planet) is not int or not 0 <= planet <= 10000 or planet in seen:
            raise ValueError("星球索引无效或重复")
        seen.add(planet)
        effects = raw.get("effects")
        if effects is None:
            effects = plan.get("variants", {}).get(raw.get("variant"), [])
        if not isinstance(effects, list) or len(effects) > 32 or any(type(e) is not int or e <= 0 for e in effects):
            raise ValueError("效果配置无效")
        owner, campaign_type = raw.get("owner", 0), raw.get("campaign_type", 0)
        campaign_race = raw.get("campaign_race", 0)
        if type(campaign_race) is not int or campaign_race not in (0, 1, 2, 3, 4):
            raise ValueError("作战敌人阵营无效")
        if type(owner) is not int or owner not in range(5) or type(campaign_type) is not int or campaign_type not in range(5):
            raise ValueError("阵营或战役类型无效")
        campaign = raw.get("campaign", False)
        if type(campaign) is not bool:
            raise ValueError("战役开关无效")
        force_open = raw.get('force_open', False)
        if type(force_open) is not bool:
            raise ValueError('强制开放开关必须为布尔值')
        campaign = campaign or force_open
        open_regions=raw.get('open_regions',False)
        if type(open_regions) is not bool:
            raise ValueError("分区开放开关必须为布尔值")
        initialize_regions=raw.get('initialize_regions',False)
        if type(initialize_regions) is not bool:
            raise ValueError("分区初始化开关必须为布尔值")
        if initialize_regions and (not campaign or campaign_race not in (2,3,4)):
            raise ValueError("初始化分区需要开启战役并明确选择作战敌人")
        defense = {key: raw.get(key, default) for key, default in (
            ('defense_source', -1), ('defense_level', 20), ('defense_hours', 48), ('defense_count', 38))}
        for key, low, high in (('defense_source', -1, 10000), ('defense_level', 1, 1000), ('defense_hours', 1, 168), ('defense_count', 1, 1000)):
            if type(defense[key]) is not int or not low <= defense[key] <= high:
                raise ValueError('防守战役参数无效：' + key)
        campaign_count = raw.get('campaign_count', 20)
        if type(campaign_count) is not int or not 1 <= campaign_count <= 1000:
            raise ValueError('作战数量无效')
        if campaign_type == 4:
            if not campaign or owner != 1 or campaign_race not in (2, 3, 4):
                raise ValueError('防守战役需要开启战役、超级地球归属和明确的敌人阵营')
            if defense['defense_source'] < 0 or defense['defense_source'] == planet:
                raise ValueError('请选择另一颗敌方星球作为进攻来源')
        result.append(dict(planet=planet, effects=list(dict.fromkeys(effects)), owner=owner, campaign=campaign, force_open=force_open, campaign_type=campaign_type, campaign_race=campaign_race,open_regions=open_regions,initialize_regions=initialize_regions,campaign_count=campaign_count, **defense))
    return result


class RegionAvailabilityError(ValueError):
    pass


def apply_defense(result, target, campaign, states):
    """Build the linked Status records together; never mutate an unrelated event."""
    import math
    now = result.get('time')
    if type(now) not in (int, float) or not math.isfinite(now) or now < 0:
        raise ValueError('防守战役缺少有效的战况时间')
    source = next((p for p in result['planetStatus'] if p['index'] == target['defense_source']), None)
    if source is None or source.get('owner') != target['campaign_race']:
        raise ValueError('进攻来源不在本次战况中，或其归属与所选敌人阵营不符')
    for name in ('planetAttacks', 'planetEvents', 'jointOperations'):
        if not isinstance(result.get(name), list) or any(not isinstance(row, dict) for row in result[name]):
            raise ValueError('防守战役响应结构不兼容：' + name)
    events, joints = result['planetEvents'], result['jointOperations']
    for row in events + joints:
        if type(row.get('id')) is not int or row['id'] < 0 or type(row.get('planetIndex')) is not int:
            raise ValueError('防守事件或联合作战编号不兼容')
    pid = target['planet']
    event = next((e for e in events if e['planetIndex'] == pid and e.get('eventType') == 1 and e.get('campaignId') == campaign['id']), None)
    if any(e['planetIndex'] == pid and e.get('eventType') == 1 and e is not event for e in events):
        raise ValueError('目标星球已有另一条防守事件，请选择其他星球或保留原生战役')
    signature = (campaign['id'], target['defense_source'], target['campaign_race'], target['defense_hours'])
    state = states.get(pid)
    used = {r['id'] for r in events + joints}
    if event is not None:
        eid = event['id']
        start, expire = event.get('startTime'), event.get('expireTime')
    elif state and state['signature'] == signature:
        eid, start, expire = state['id'], state['start'], state['expire']
        if eid in used:
            eid = max(used | {9100 + pid}) + 1
    else:
        eid = max(used | {9100 + pid}) + 1
        start, expire = now, now + target['defense_hours'] * 3600
    if eid >= 2**31 or any(type(t) not in (int, float) or not math.isfinite(t) for t in (start, expire)) or expire <= start:
        raise ValueError('防守战役编号或时间无效')
    if any(j['id'] == eid and j['planetIndex'] != pid for j in joints):
        raise ValueError('防守联合作战编号与其他星球冲突')
    edge = {'source': target['defense_source'], 'target': pid}
    if not any(a.get('source') == edge['source'] and a.get('target') == pid for a in result['planetAttacks']):
        result['planetAttacks'].append(edge)
    maximum = target['defense_level'] * 50000
    fields = dict(id=eid, planetIndex=pid, eventType=1, race=target['campaign_race'], health=maximum * 99 // 100,
                  maxHealth=maximum, startTime=start, expireTime=expire, campaignId=campaign['id'], jointOperationIds=[eid], potentialBuildUp=0)
    if event is None:
        events.append(fields)
    else:
        event.update(fields)
    joint = next((j for j in joints if j['id'] == eid), None)
    if joint is None:
        joints.append(dict(id=eid, planetIndex=pid, hqNodeIndex=2))
    campaign['count'] = target['defense_count']
    states[pid] = dict(signature=signature, id=eid, start=start, expire=expire)


def patch_planet_regions(regions, definitions, target, skipped):
    """Prepare one planet's rows before changing any of them."""
    planet = target['planet']
    if not isinstance(regions, list):
        raise RegionAvailabilityError('当前战况不包含有效分区列表')
    positions = {}
    for position, row in enumerate(regions):
        if not isinstance(row, dict):
            raise RegionAvailabilityError('原生分区结构不兼容')
        if row.get('planetIndex') != planet:
            continue
        index = row.get('regionIndex')
        if type(index) is not int or index < 0 or index in positions:
            raise RegionAvailabilityError('原生分区编号无效或重复')
        positions[index] = position

    replacements = {}
    additions = []
    if target['initialize_regions']:
        if definitions is None:
            raise RegionAvailabilityError('缺少当前战争及布局对应的原生分区定义')
        native = [row for row in definitions if isinstance(row, dict) and row.get('planetIndex') == planet]
        if not native:
            skipped.append((planet, '所选星球没有原生分区定义'))
        seen = set()
        for row in native:
            index, maximum = row.get('regionIndex'), row.get('maxHealth')
            if type(index) is not int or index < 0 or index in seen or type(maximum) is not int or maximum <= 1:
                raise RegionAvailabilityError('原生分区编号或生命值上限不兼容')
            seen.add(index)
            if index not in positions:
                additions.append(dict(planetIndex=planet, regionIndex=index, owner=target['campaign_race'],
                                      health=maximum//2, players=0, regerPerSecond=0,
                                      isAvailable=True, availabilityFactor=1))
                continue
            position = positions[index]
            original = regions[position]
            region = dict(original, owner=target['campaign_race'], isAvailable=True)
            factor = region.get('availabilityFactor')
            if type(factor) not in (int, float) or not math.isfinite(factor) or factor <= 0:
                region['availabilityFactor'] = 1
            health = region.get('health')
            if type(health) not in (int, float) or not math.isfinite(health) or not 0 < health <= maximum:
                region['health'] = maximum//2
            if region != original:
                replacements[position] = region

    if target['open_regions']:
        if not positions and not additions:
            skipped.append((planet, '所选星球缺少原生分区状态'))
        for position in positions.values():
            original = regions[position]
            region = replacements.get(position, original)
            factor = region.get('availabilityFactor')
            if type(region.get('isAvailable')) is not bool or type(factor) not in (int, float) or not math.isfinite(factor):
                raise RegionAvailabilityError('原生分区可用性字段不兼容，已保持原样')
            health = region.get('health')
            if type(health) in (int, float) and health <= 0:
                skipped.append((planet, '分区血量为 0，未开放'))
                continue
            if not region['isAvailable'] or factor <= 0:
                replacements[position] = dict(region, isAvailable=True, availabilityFactor=factor if factor > 0 else 1)
    for position, replacement in replacements.items():
        regions[position] = replacement
    regions.extend(additions)
    return len(replacements) + len(additions)


def enemy_for_plan(target, planet, campaigns, entries):
    for race in (target['campaign_race'], target['owner']):
        if race in (2, 3, 4):
            return race
    native = {c.get('race') for c in campaigns if c.get('planetIndex') == target['planet']
              and c.get('race') in (2, 3, 4)}
    if len(native) == 1:
        return next(iter(native))
    owner = planet.get('owner')
    if owner in (2, 3, 4):
        return owner
    effects = {NATIVE_ENEMY_EFFECTS[e['galacticEffectId']] for e in entries
               if e['index'] == target['planet'] and e['galacticEffectId'] in NATIVE_ENEMY_EFFECTS}
    return next(iter(effects)) if len(effects) == 1 else None


def rewrite_status(document, plan, allowed, campaign_ids=None, effect_types=None,
                   region_reference=None, defense_states=None,
                   region_skips=None, recovery=None):
    """Pure transformation; malformed/unknown schema must fail before mutation."""
    if not isinstance(document, dict):
        raise ValueError("战况响应不是对象，已保持原样")
    entries = document.get("planetActiveEffects")
    planets = document.get("planetStatus")
    if not isinstance(entries, list) or not isinstance(planets, list):
        raise ValueError("战况结构不兼容，已保持原样")
    if any(not isinstance(p, dict) or type(p.get("index")) is not int for p in planets):
        raise ValueError("星球条目结构不兼容，已保持原样")
    pairs = set()
    for entry in entries:
        if not isinstance(entry, dict) or type(entry.get("index")) is not int or type(entry.get("galacticEffectId")) is not int:
            raise ValueError("星球效果条目结构不兼容，已保持原样")
        pairs.add((entry["index"], entry["galacticEffectId"]))
    known_planets = {p["index"] for p in planets if isinstance(p, dict) and type(p.get("index")) is int}
    additions = []
    targets = normalize_targets(plan)
    if recovery is not None:
        missing = [t['planet'] for t in targets if t['planet'] not in known_planets]
        if missing:
            recovery['missing_planets'] = missing
        targets = [t for t in targets if t['planet'] in known_planets]
        for target in targets:
            unsupported = [eid for eid in target['effects'] if allowed is None or eid not in allowed]
            if unsupported:
                recovery.setdefault('unavailable_effects', {})[target['planet']] = unsupported
                target['effects'] = [eid for eid in target['effects'] if eid not in unsupported]
    if recovery is None:
        target_owners = {t['planet']:t['owner'] for t in targets if t['owner']}
        for target in targets:
            if target['campaign_type'] == 4 and target['defense_source'] in target_owners and target_owners[target['defense_source']] != target['campaign_race']:
                raise ValueError('进攻来源的另一份方案会改变其阵营，请先解决冲突')
    # Both members must be present in this session's authoritative catalog and
    # retain their verified types. Cached display data never grants permission.
    if effect_types and allowed is not None:
        for target in targets:
            for tag, presence in EFFECT_PAIRS:
                if (tag in target['effects'] or presence in target['effects']) and effect_types.get(tag)==40 and effect_types.get(presence)==71 and tag in allowed and presence in allowed:
                    for eid in (tag, presence):
                        if eid not in target['effects']:
                            target['effects'].append(eid)
    campaigns = document.get("campaigns", [])
    if any(t["campaign"] or t["owner"] or t["campaign_race"] for t in targets) and (not isinstance(campaigns, list) or any(not isinstance(c, dict) or type(c.get("id")) is not int or type(c.get("planetIndex")) is not int for c in campaigns)):
        raise ValueError("战役结构不兼容，已保持原样")
    for target in targets:
        planet = target["planet"]
        if planet not in known_planets:
            raise ValueError("星球 #"+str(planet)+" 不在本次战况中，已保持原样")
        for effect in target["effects"]:
            if allowed is None or effect not in allowed:
                raise ValueError("效果 #"+str(effect)+" 不在本次战争目录中，已保持原样")
        for effect in target["effects"]:
            if (planet, effect) not in pairs:
                additions.append({"index": planet, "galacticEffectId": effect})
                pairs.add((planet, effect))
    # Work on copies only: one bad target must never leave a partially changed body.
    result = copy.deepcopy(document)
    next_defense_states = copy.deepcopy(defense_states) if defense_states is not None else {}
    result["planetActiveEffects"] = entries + additions
    changes = len(additions)
    definitions = None
    if (isinstance(region_reference, dict)
            and region_reference.get('warId') == document.get('warId')
            and region_reference.get('layoutVersion') == document.get('layoutVersion')
            and isinstance(region_reference.get('planetRegions'), list)):
        definitions = region_reference['planetRegions']
    if recovery is not None and definitions is not None and 'planetRegions' not in result:
        result['planetRegions'] = []
    world_info = {}
    if definitions is not None and isinstance(region_reference.get('planetInfos'), list):
        world_info = {row['index']: row for row in region_reference['planetInfos']
                      if isinstance(row, dict) and type(row.get('index')) is int}
    native_planets = {row.get('planetIndex') for row in (definitions or [])
                      if isinstance(row, dict) and type(row.get('planetIndex')) is int}
    for target in targets:
        pid = target['planet']
        if recovery is not None and target['campaign']:
            planet = next(row for row in planets if row['index'] == pid)
            race = enemy_for_plan(target, planet, campaigns, entries)
            if target['force_open'] and target['campaign_type'] != 4:
                target['campaign_race'] = target['owner'] = race or 2
            elif not any(c['planetIndex'] == pid for c in campaigns):
                target['campaign_race'] = race or 2
            if target['campaign_type'] in (0, 3) and pid in native_planets:
                target['campaign_race'] = race or 2
                target['initialize_regions'] = True
        if target['initialize_regions'] or target['open_regions']:
            skipped = []
            try:
                changes += patch_planet_regions(result.get('planetRegions'), definitions, target, skipped)
            except RegionAvailabilityError as error:
                if recovery is None:
                    raise
                skipped = [(pid, str(error))]
            if region_skips is not None:
                region_skips.extend(skipped)
            if recovery is not None and target['initialize_regions'] and pid in native_planets and not skipped:
                recovery.setdefault('initialized', []).append(pid)
        if recovery is not None and target['campaign'] and target['campaign_type'] == 3:
            regions = result.get('planetRegions')
            planet = next(row for row in planets if row['index'] == pid)
            race = enemy_for_plan(target, planet, campaigns, entries)
            usable = isinstance(regions, list) and any(
                isinstance(row, dict) and row.get('planetIndex') == pid
                and row.get('owner') == race and row.get('isAvailable') is True
                and type(row.get('regionIndex')) is int
                and type(row.get('health')) in (int, float) and 0 < row['health'] < math.inf
                and type(row.get('availabilityFactor')) in (int, float)
                and 0 < row['availabilityFactor'] < math.inf for row in regions)
            if not usable:
                target['campaign_type'] = 0
                recovery.setdefault('campaign_fallbacks', {})[pid] = '分区不可用，改用常规解放'
    output_campaign_ids = campaign_ids
    campaign_ids = dict(campaign_ids) if campaign_ids is not None else {}
    used_ids = {c["id"] for c in campaigns} if any(t["campaign"] or t["owner"] for t in targets) else set()
    original_owners = {p['index']: p.get('owner') for p in planets}
    output_planets = {p['index']: p for p in result['planetStatus']}
    for target in targets:
        planet = output_planets[target['planet']]
        if target['owner'] and planet.get('owner') != target['owner']:
            planet['owner'] = target['owner']
            changes += 1
        if recovery is not None and target['force_open'] and target['campaign_type'] != 4:
            maximum = world_info.get(target['planet'], {}).get('maxHealth')
            health = planet.get('health')
            if type(maximum) is int and maximum > 1 and type(health) in (int, float) and health <= 0:
                planet['health'] = maximum//2
                changes += 1
    for target in targets:
        planet = output_planets[target['planet']]
        original_owner = original_owners[target['planet']]
        native_races = {NATIVE_ENEMY_EFFECTS[e['galacticEffectId']] for e in entries if e['index'] == target['planet'] and e['galacticEffectId'] in NATIVE_ENEMY_EFFECTS}
        inferred_race = original_owner if original_owner in (2, 3, 4) else next(iter(native_races)) if len(native_races) == 1 else 1
        requested_race = target['campaign_race'] or (target['owner'] if target['owner'] in (2, 3, 4) else 0)
        if requested_race:
            for campaign in result.get("campaigns", []):
                if campaign["planetIndex"] == target["planet"] and campaign.get("race") != requested_race:
                    campaign["race"] = requested_race
                    changes += 1
        if target["campaign"]:
            current = next((c for c in result.get("campaigns", []) if c["planetIndex"] == target["planet"]), None)
            if current is None:
                candidate = campaign_ids.get(target["planet"])
                if candidate is None or candidate in used_ids:
                    candidate = max(used_ids | {0}) + 1
                if candidate >= 2**31:
                    raise ValueError("无法分配实验性战役编号")
                campaign_ids[target["planet"]] = candidate
                used_ids.add(candidate)
                current = {"id": candidate, "planetIndex": target["planet"], "type": target["campaign_type"], "count": target["campaign_count"], "race": requested_race or inferred_race}
                result.setdefault("campaigns", []).append(current)
                changes += 1
            elif current.get("type") != target["campaign_type"]:
                current["type"] = target["campaign_type"]
                changes += 1
            if type(current.get('count')) is not int or current['count'] <= 0 or (
                    recovery is not None and (target['force_open'] or target['initialize_regions'])
                    and current['count'] < target['campaign_count']):
                current['count'] = target['campaign_count']
                changes += 1
            if requested_race and current.get("race") != requested_race:
                current["race"] = requested_race
                changes += 1
            if target['campaign_type'] == 4:
                before = copy.deepcopy(result)
                try:
                    apply_defense(result, target, current, next_defense_states)
                except ValueError as error:
                    if recovery is None:
                        raise
                    # An incompatible defense cannot make unrelated planets fail.
                    result.update(before)
                    output_planets = {p['index']: p for p in result['planetStatus']}
                    pid = target['planet']
                    existing = [c for c in campaigns if c['planetIndex'] == pid]
                    native_events = document.get('planetEvents')
                    has_native_defense = any(c.get('type') == 4 for c in existing) or (
                        isinstance(native_events, list) and any(
                            isinstance(e, dict) and e.get('planetIndex') == pid and e.get('eventType') == 1
                            for e in native_events))
                    if has_native_defense:
                        untouched = iter(copy.deepcopy(existing))
                        restored = []
                        for row in result['campaigns']:
                            if row['planetIndex'] != pid:
                                restored.append(row)
                                continue
                            original = next(untouched, None)
                            if original is not None:
                                restored.append(original)
                        result['campaigns'] = restored
                        if 'owner' in next(p for p in planets if p['index'] == pid):
                            output_planets[pid]['owner'] = original_owner
                        else:
                            output_planets[pid].pop('owner', None)
                        reason = '防守配置不可用，保留原生防守'
                    else:
                        for row in result['campaigns']:
                            if row['id'] == current['id']:
                                row.update(type=0, count=target['campaign_count'], race=target['campaign_race'])
                        output_planets[pid]['owner'] = target['campaign_race']
                        reason = '防守配置不可用，改用常规解放'
                    recovery.setdefault('campaign_fallbacks', {})[pid] = f'{reason}（{error}）'
                    changes += 1
                else:
                    changes += int(result != before)
    if defense_states is not None:
        defense_states.clear()
        defense_states.update(next_defense_states)
    if output_campaign_ids is not None:
        output_campaign_ids.clear()
        output_campaign_ids.update(campaign_ids)
    return result if changes else document, changes


class WarStatusAddon:
    def __init__(self):
        self.plan = None
        self.armory_weapons = {}
        self.armory_stratagems = ()
        self.inventory = {"responses": 0, "status": "waiting", "http_status": 0, "added": 0}
        self.item_catalog = {**self.inventory, "missing_templates": 0}
        self.allowed = None
        self.effect_types = {}
        self.rewrites = 0
        self.health_path = None
        self.plan_path = None
        self.plan_stamp = None
        self.plan_digest = None
        self.applied_plan_digest = None
        self.campaign_ids = {}
        self.defense_states = {}
        self.statuses = 0
        self.catalog_count = 0
        self.war_id = None
        self.region_reference = None
        self.region_reference_error = None
        self.region_reference_lock = asyncio.Lock()
        self.region_reference_retry = {}
        self.shutting_down = False
        self.ready = False
        self.revocation_service = None
        self.api_router = None
        self.last_message = "插件已加载，捕获尚未就绪"
        self.failures = {"client_tls": 0, "server_tls": 0, "connect": 0, "http": 0}
        self.connection = {"client_tls": 0, "server_tls": 0, "requests": 0, "responses": 0, "last_status": 0, "failure_kind": ""}

    def health(self, message):
        self.last_message = message
        if not self.health_path:
            return
        try:
            target = Path(self.health_path)
            temporary = target.with_suffix(".tmp")
            temporary.write_text(json.dumps({"message": message, "ready": self.ready, "router_port": self.api_router.port if self.api_router else 0, "failures": self.failures, "connection": self.connection, "inventory": self.inventory, "item_catalog": self.item_catalog, "rewrites": self.rewrites, "statuses": self.statuses, "catalog_count": self.catalog_count, "war_id": self.war_id, "applied_plan_digest": self.applied_plan_digest, "updated": time.time()}, ensure_ascii=False), encoding="utf-8")
            os.replace(temporary, target)
        except OSError:
            pass  # Diagnostics must not break forwarding.

    def load(self, loader):
        self.plan_path = Path(os.environ["CPV_WAR_PLAN"])
        self.armory_weapons = {item_id: (kind, model) for item_id, kind, model in
                               json.loads(os.environ.get("CPV_ARMORY_WEAPON_CATALOG", "[]"))}
        self.armory_stratagems = tuple(json.loads(os.environ.get("CPV_ARMORY_STRATAGEM_LICENSES", "[]")))
        self.plan = json.loads(self.plan_path.read_text(encoding="utf-8"))
        self.plan_digest = hashlib.sha256(self.plan_path.read_bytes()).hexdigest()
        normalize_targets(self.plan)
        self.plan_stamp = self.plan_path.stat().st_mtime_ns
        self.health_path = self.plan["health_path"]
        self.health("插件已加载，等待游戏获取效果目录")

    def snapshot(self, name, data):
        if self.health_path:
            target = Path(self.health_path).parent / name
            temporary = target.with_suffix(".tmp")
            try:
                temporary.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
                os.replace(temporary, target)
            except OSError:
                pass

    def reload_plan(self):
        if self.plan_path:
            raw = self.plan_path.read_bytes()
            digest = hashlib.sha256(raw).hexdigest()
            if digest == self.plan_digest:
                return
            candidate = json.loads(raw)
            normalize_targets(candidate)
            self.plan = candidate
            self.plan_stamp = self.plan_path.stat().st_mtime_ns
            self.plan_digest = digest
            self.health("方案已更新，等待下一次游戏战况刷新；当前地图和已生成作战可能仍使用缓存")

    def tick(self):
        # Shutdown is owned by this process' private profile directory, not a
        # network endpoint. Let the upstream core release its capture helper.
        if self.health_path and (Path(self.health_path).parent / "stop.request").exists() and not self.shutting_down:
            from mitmproxy import ctx
            self.shutting_down = True
            ctx.master.shutdown()
        if not self.shutting_down:
            try:
                self.reload_plan()
            except (ValueError, OSError) as error:
                self.health("新方案未通过校验，继续保留上次有效方案："+str(error)[:100])

    def request(self, flow):
        request = flow.request
        if request.pretty_host.lower() == HOST:
            self.connection["requests"] += 1
        path = request.path.split('?', 1)[0]
        if request.method == 'GET' and request.pretty_host.lower() == HOST and (
                STATUS.fullmatch(path) or path == "/api/WarSeason/GalacticWarEffects"
                or path.lower().removesuffix('/') in ARMORY_ENDPOINTS):
            # Request a full response for the public catalogs and locally previewed inventory.
            for name in ('if-none-match', 'if-modified-since'):
                request.headers.pop(name, None)
            request.headers['cache-control']='no-cache'

    def running(self):
        import asyncio
        if os.environ.get("CPV_PREPARE_CA") == "1":
            from mitmproxy import ctx
            ctx.master.shutdown()
            return
        from mitmproxy import ctx
        self.revocation_service = LocalRevocationService(ctx.master.addons.get("tlsconfig").certstore)
        # Use the official custom-cert option so a later TLSConfig configure
        # event cannot replace our session certificate with one without a CDP.
        cert_path = self.plan_path.parent / "session-api-cert.pem"
        cert_path.write_bytes(self.revocation_service.certificate)
        ctx.options.update(certs=[HOST + "=" + str(cert_path)])
        if os.environ.get("CPV_WAR_MITM_PORT"):
            self.api_router = ApiOnlyRouter(int(os.environ["CPV_WAR_MITM_PORT"]))
        self.ready = True
        self.health("捕获服务已就绪，等待游戏连接")
        async def watch():
            ticks = 0
            while not self.shutting_down:
                self.tick()
                ticks += 1
                if ticks % 20 == 0:
                    self.health(self.last_message)
                await asyncio.sleep(0.25)
        asyncio.create_task(watch())

    def done(self):
        self.shutting_down = True
        self.ready = False
        if self.revocation_service:
            self.revocation_service.close()
            self.revocation_service = None
        if self.api_router:
            self.api_router.close()
            self.api_router = None

    @staticmethod
    def api_tls(data):
        context = getattr(data, "context", None)
        client = getattr(context, "client", None)
        server = getattr(context, "server", None)
        return getattr(client, "sni", None) == HOST or getattr(server, "sni", None) == HOST

    def tls_failed_client(self, data):
        if self.api_tls(data):
            self.failures["client_tls"] += 1
            self.connection["failure_kind"] = self.tls_failure_kind(data)
            self.health("游戏 API 的客户端 TLS 握手失败；当前用户信任 CA 不代表游戏的 TLS 后端接受该 CA")

    def tls_failed_server(self, data):
        if self.api_tls(data):
            self.failures["server_tls"] += 1
            self.connection["failure_kind"] = self.tls_failure_kind(data)
            self.health("游戏 API 的上游 TLS 握手失败；未关闭服务器证书验证，请检查上游代理或路由")

    @staticmethod
    def tls_failure_kind(data):
        # Persist only an allowlisted category, never the raw connection error:
        # third-party errors may include addresses, request URLs or credentials.
        context = getattr(data, "context", None)
        text = " ".join(str(getattr(getattr(context, side, None), "error", "") or "") for side in ("client", "server")).lower()
        for needles, category in ((["revocation", "revoked"], "吊销检查失败"), (["unknown ca", "certificate verify", "certificate_unknown", "unknown_ca"], "证书信任失败"), (["timeout", "timed out"], "连接超时"), (["protocol version", "no shared cipher"], "TLS 协议不兼容"), (["reset", "closed", "eof"], "对端断开连接")):
            if any(word in text for word in needles):
                return category
        return "TLS 握手失败（原因未分类）"

    def tls_established_client(self, data):
        if self.api_tls(data):
            self.connection["client_tls"] += 1
            self.health("游戏 API 的客户端 TLS 已连接，等待 API 响应")

    def tls_established_server(self, data):
        if self.api_tls(data):
            self.connection["server_tls"] += 1
            self.health("游戏 API 的上游 TLS 已连接，等待 API 响应")

    def server_connect_error(self, data):
        server = getattr(data, "server", None)
        address = getattr(server, "address", None)
        if getattr(server, "sni", None) == HOST or (address and address[0] == HOST):
            self.failures["connect"] += 1
            self.health("无法建立到游戏 API 的上游连接；请检查既有代理、TUN 或路由")

    def error(self, flow):
        request = getattr(flow, "request", None)
        if request and getattr(request, "pretty_host", "").lower() == HOST:
            self.failures["http"] += 1
            # Only fixed categories are retained. Do not expose full URLs,
            # request payloads or third-party error strings in diagnostics.
            text = str(getattr(getattr(flow, "error", None), "msg", "") or "").lower()
            kind = "HTTP 转发失败（原因未分类）"
            for words, label in ((["http/2", "http2", "stream reset"], "HTTP/2 流失败"), (["timeout", "timed out"], "请求超时"), (["certificate", "tls", "ssl"], "上游 TLS 失败"), (["reset", "closed", "eof", "disconnect"], "连接被对端关闭"), (["refused", "unreachable"], "上游不可达")):
                if any(word in text for word in words):
                    kind = label
                    break
            path = getattr(request, "path", "").split("?", 1)[0]
            category = "战况接口" if path.startswith("/api/WarSeason/") else "作战接口" if path.startswith("/api/Operation/") else "其他游戏 API"
            self.connection["failure_kind"] = kind
            self.connection["failed_endpoint"] = category
            version = getattr(request, "http_version", "")
            self.connection["failed_protocol"] = version if version in ("HTTP/1.0", "HTTP/1.1", "HTTP/2", "HTTP/3") else "未知"
            if request.method == "CONNECT":
                self.health("捕获到了既有 HTTP 代理的 CONNECT 隧道；透明捕获与现有代理链可能不兼容")
            else:
                self.health(category + "转发失败：" + kind + "。此前成功的响应不代表此请求成功。")

    def fetch_region_reference(self, war_id):
        # Public static endpoint only. No account headers, cookies or proxy loop.
        opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open("https://"+HOST+"/api/WarSeason/"+str(war_id)+"/WarInfo",timeout=3) as reply:
            raw=reply.read(MAX_BODY+1)
        if len(raw)>MAX_BODY:
            raise ValueError('原生分区定义响应过大')
        doc=json.loads(raw)
        if not isinstance(doc,dict) or doc.get('warId')!=war_id or not isinstance(doc.get('planetRegions'),list):
            raise ValueError('原生分区定义战争编号或结构不匹配')
        return doc

    async def response(self, flow):
        request=flow.request;response=flow.response
        path=request.path.split('?',1)[0]
        if request.method=='GET' and request.pretty_host.lower()==HOST and response.status_code==200 and STATUS.fullmatch(path):
            try:
                self.reload_plan()
                if any(t['initialize_regions'] or (t['campaign'] and t['campaign_type'] in (0, 3))
                       for t in normalize_targets(self.plan)):
                    raw=response.content
                    if raw is not None and len(raw)<=MAX_BODY:
                        document=json.loads(raw);war_id=int(path.split('/')[3])
                        if not isinstance(document,dict):
                            raise ValueError('战况不是对象')
                        layout = document.get('layoutVersion')
                        if type(layout) is int:
                            async with self.region_reference_lock:
                                key = (war_id, layout)
                                matches = (self.region_reference is not None
                                           and self.region_reference.get('warId') == war_id
                                           and self.region_reference.get('layoutVersion') == layout)
                                if not matches and time.monotonic() >= self.region_reference_retry.get(key, 0):
                                    self.region_reference_retry = {key: time.monotonic() + 15}
                                    reference = await asyncio.to_thread(self.fetch_region_reference, war_id)
                                    if reference.get('layoutVersion') != layout:
                                        raise ValueError('原生分区与战况布局不一致')
                                    self.region_reference = reference
                                    self.region_reference_error = None
                                    self.region_reference_retry.clear()
            except (ValueError,TypeError,KeyError,OSError) as error:
                self.region_reference_error=type(error).__name__
        self.process_response(flow)

    def preview_armory(self, response, endpoint, report):
        if not self.plan_path:
            return "missing_plan"
        try:
            with self.plan_path.with_name("inventory-preview.json").open("rb") as config:
                raw_plan = config.read(65537)
            if len(raw_plan) > 65536:
                return "invalid_plan"
            plan = json.loads(raw_plan)
        except FileNotFoundError:
            return "missing_plan"
        except (OSError, ValueError):
            return "invalid_plan"
        if not isinstance(plan, dict) or type(plan.get("enabled")) is not bool:
            return "invalid_plan"
        if not plan["enabled"]:
            return "disabled"
        try:
            raw = response.content
            if raw is None or len(raw) > MAX_BODY:
                return "unsupported_response"
            original = json.loads(raw)
            if endpoint == "item_catalog":
                current_licenses = stratagem_licenses(original)
                if current_licenses:
                    self.armory_stratagems = current_licenses
                changed, report["missing_templates"] = rewrite_weapon_catalog(original, plan, self.armory_weapons)
            else:
                changed = rewrite_inventory(original, plan, self.armory_weapons, self.armory_stratagems)
        except (ValueError, TypeError):
            return "unsupported_response"
        if changed is original:
            return "missing_template" if report.get("missing_templates") else "unchanged"
        added = (len(changed) - len(original) if endpoint == "item_catalog"
                 else len(changed["items"]) - len(original["items"]))
        response.content = json.dumps(changed, separators=(",", ":")).encode("utf-8")
        for name in ("etag", "last-modified", "content-md5", "digest"):
            response.headers.pop(name, None)
        response.headers["cache-control"] = "no-store"
        report["added"] = added
        return "applied"

    def process_response(self, flow):
        request, response = flow.request, flow.response
        if request.pretty_host.lower() == HOST:
            self.connection["responses"] += 1
            self.connection["last_status"] = int(response.status_code)
            if response.status_code >= 400:
                self.health("游戏 API 返回 HTTP " + str(int(response.status_code)) + "；未修改此响应")
        if request.method != "GET" or request.pretty_host.lower() != HOST:
            return
        path = request.path.split("?", 1)[0]
        endpoint = ARMORY_ENDPOINTS.get(path.lower().removesuffix('/'))
        if endpoint:
            report = self.item_catalog if endpoint == "item_catalog" else self.inventory
            report.update(responses=report["responses"] + 1, http_status=response.status_code, added=0)
            if endpoint == "item_catalog":
                report["missing_templates"] = 0
            report["status"] = self.preview_armory(response, endpoint, report) if response.status_code == 200 else "http_error"
            self.health(self.last_message)
            return
        if response.status_code != 200:
            return
        if path != "/api/WarSeason/GalacticWarEffects" and not STATUS.fullmatch(path) and not WAR_INFO.fullmatch(path):
            return
        try:
            if path == "/api/WarSeason/GalacticWarEffects":
                self.allowed = None
                self.effect_types = {}
                self.catalog_count = 0
            raw = response.content
            if raw is None or len(raw) > MAX_BODY:
                raise ValueError("响应为空或过大，已保持原样")
            document = json.loads(raw)
            if WAR_INFO.fullmatch(path):
                if not isinstance(document,dict):
                    raise ValueError("WarInfo 不是对象")
                regions=document.get('planetRegions',[])
                if not isinstance(regions,list):
                    raise ValueError("WarInfo 分区定义格式不兼容")
                if (document.get('warId') == int(path.split('/')[3])
                        and type(document.get('layoutVersion')) is int):
                    self.region_reference = document
                    self.region_reference_error = None
                    self.region_reference_retry.clear()
                fields=('planetIndex','regionIndex','settingsHash','maxHealth','regionSize','flags','damageMultiplier')
                self.snapshot('planet-region-definitions.json',{'war_id':int(path.split('/')[3]),'regions':[
                    {k:r[k] for k in fields if type(r.get(k)) in (int,float)} for r in regions if isinstance(r,dict)],'updated':time.time()})
                self.health("已采集原生星球分区定义，未修改 WarInfo；分区作战生成仍未验证")
                return
            if path == "/api/WarSeason/GalacticWarEffects":
                rows = document.get("galacticEffects") if isinstance(document, dict) else document
                if not isinstance(rows, list) or not rows or any(not isinstance(r, dict) or type(r.get("id")) is not int for r in rows):
                    self.allowed = None
                    raise ValueError("效果目录结构不兼容，禁止改写")
                if any(r['id']<=0 or ('effectType' in r and (type(r['effectType']) is not int or r['effectType']<0)) for r in rows) or len({r['id'] for r in rows}) != len(rows):
                    raise ValueError("效果目录 ID 重复或类型无效，禁止改写")
                self.allowed = {r["id"] for r in rows}
                self.effect_types = {r['id']: r.get('effectType') for r in rows}
                self.catalog_count = len(rows)
                public = [{k: row[k] for k in ("id", "effectType", "nameHash", "descriptionGamePlayShortHash") if type(row.get(k)) is int} for row in rows]
                self.snapshot("catalog.json", {"effects": public, "updated": time.time()})
                self.health("已收到本次效果目录，等待战况响应")
                return
            self.reload_plan()
            war_id = int(path.split("/")[3])
            if self.war_id is not None and self.war_id != war_id:
                self.campaign_ids.clear()
                self.defense_states.clear()
            self.war_id = war_id
            self.statuses += 1
            planets = document.get("planetStatus", []) if isinstance(document, dict) else []
            public = [{k: p[k] for k in ("index", "owner", "health", "players") if type(p.get(k)) in (int, float)} for p in planets if isinstance(p, dict) and type(p.get("index")) is int]
            self.snapshot("planets.json", {"planets": public, "war_id": war_id, "updated": time.time()})
            region_error = None
            region_skips = []
            recovery = {}
            changed, count = rewrite_status(
                document, self.plan, self.allowed, self.campaign_ids, self.effect_types,
                self.region_reference, self.defense_states, region_skips, recovery)
            if region_skips:
                skipped = dict(region_skips)
                region_error = '；'.join('星球 #'+str(pid)+'：'+reason for pid, reason in sorted(skipped.items()))
            if count:
                response.content = json.dumps(changed, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
                for header in ("etag", "content-md5", "digest"):
                    response.headers.pop(header, None)
                self.rewrites += 1
            target_ids = {t['planet'] for t in normalize_targets(self.plan)}
            # Optional diagnostics must tolerate missing/null metadata. They
            # must not turn a successfully rewritten response into an error.
            event_rows = document.get('planetEvents')
            event_rows = [e for e in event_rows if isinstance(e,dict)] if isinstance(event_rows,list) else []
            joint_rows = document.get('jointOperations')
            joint_rows = [e for e in joint_rows if isinstance(e,dict)] if isinstance(joint_rows,list) else []
            # Public structural diagnostics only, never Operation requests or accounts.
            self.snapshot('campaign-diagnostics.json', {'war_id': war_id, 'targets': [
                {'planet': pid,
                 'input_owner': next((p.get('owner') for p in document.get('planetStatus',[]) if p.get('index')==pid),None),
                 'output_owner': next((p.get('owner') for p in changed.get('planetStatus',[]) if p.get('index')==pid),None),
                 'server_campaigns': [{k:c[k] for k in ('id','planetIndex','type','count','race') if k in c}
                  for c in document.get('campaigns',[]) if c.get('planetIndex')==pid],
                 'server_effects': [e['galacticEffectId'] for e in document.get('planetActiveEffects',[]) if e.get('index')==pid],
                 'server_regions': [{k:r[k] for k in ('planetIndex','regionIndex','owner','health','isAvailable','availabilityFactor') if type(r.get(k)) in (int,float,bool)} for r in document.get('planetRegions',[]) if isinstance(r,dict) and r.get('planetIndex')==pid] if isinstance(document.get('planetRegions'),list) else [],
                 'output_regions': [{k:r[k] for k in ('planetIndex','regionIndex','owner','health','isAvailable','availabilityFactor') if type(r.get(k)) in (int,float,bool)} for r in changed.get('planetRegions',[]) if isinstance(r,dict) and r.get('planetIndex')==pid] if isinstance(changed.get('planetRegions'),list) else [],
                 'server_events': [{k:e[k] for k in ('id','planetIndex','eventType','campaignId','race','health','maxHealth','startTime','expireTime') if type(e.get(k)) in (int,float)}
                  for e in event_rows if e.get('planetIndex')==pid],
                 'server_joint_operations': [{k:e[k] for k in ('id','planetIndex','hqNodeIndex') if type(e.get(k)) is int}
                  for e in joint_rows if e.get('planetIndex')==pid],
                 'campaigns': [{k:c[k] for k in ('id','planetIndex','type','count','race') if k in c}
                  for c in changed.get('campaigns',[]) if c.get('planetIndex')==pid],
                 'effects': [e['galacticEffectId'] for e in changed.get('planetActiveEffects',[]) if e.get('index')==pid]}
                for pid in sorted(target_ids)],
                'server_schema':{name: sorted({key for row in document.get(name,[]) if isinstance(row,dict) for key in row}) for name in ('campaigns','planetEvents','jointOperations') if isinstance(document.get(name,[]),list)},
                'status_fields':sorted(document.keys()),
                'region_schemas':{name:sorted({key for row in rows if isinstance(row,dict) for key in row}) for name,rows in document.items() if 'region' in name.lower() and isinstance(rows,list)},
                'region_error':region_error, 'region_reference_error':self.region_reference_error,
                'initialized_region_planets':recovery.get('initialized', []),
                'campaign_fallbacks':recovery.get('campaign_fallbacks', {}),
                'missing_planets':recovery.get('missing_planets', []),
                'unavailable_effects':recovery.get('unavailable_effects', {}),
                'skipped_region_planets':sorted({pid for pid,_ in region_skips}), 'plan_digest':self.plan_digest, 'operation_generation_verified':False, 'updated': time.time()})
            self.applied_plan_digest = self.plan_digest
            notes = []
            if region_error:
                notes.append("分区实验未应用："+region_error)
            for pid, reason in recovery.get('campaign_fallbacks', {}).items():
                notes.append(f'星球 #{pid}：{reason}')
            if recovery.get('missing_planets'):
                notes.append('本次战况缺少星球：' + ', '.join(f'#{pid}' for pid in recovery['missing_planets']))
            if recovery.get('unavailable_effects'):
                notes.append('已跳过当前目录不支持的效果')
            self.health(("；".join(notes)+"；其余战役与效果已应用") if notes else "方案已应用到本次战况响应；已生成作战和局内效果仍需游戏验证")
        except (ValueError, KeyError, TypeError, UnicodeError, OSError) as error:
            self.health("校验未通过，响应保持原样："+str(error)[:140])


addons = [WarStatusAddon()]
