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
MAX_BODY = 8 * 1024 * 1024
# Verified type40 tag/type71 presence pairs, war 801. Never infer by ID adjacency.
EFFECT_PAIRS = ((1202,1203),(1243,1245),(1244,1386),(1248,1249),(1303,1310),
                (1306,1309),(1307,1308),(1360,1361),(1377,1378),(1380,1379),
                (1401,1400),(1402,1403),(1413,1414))
# Verified native bots_cyborgs presence. Only use ORIGINAL server effects to
# infer a liberated planet's enemy; user-added cross-faction effects don't count.
NATIVE_ENEMY_EFFECTS = {1361: 3}


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
        if campaign_type == 4:
            if not campaign or owner != 1 or campaign_race not in (2, 3, 4):
                raise ValueError('防守战役需要开启战役、超级地球归属和明确的敌人阵营')
            if defense['defense_source'] < 0 or defense['defense_source'] == planet:
                raise ValueError('请选择另一颗敌方星球作为进攻来源')
        result.append(dict(planet=planet, effects=list(dict.fromkeys(effects)), owner=owner, campaign=campaign, campaign_type=campaign_type, campaign_race=campaign_race,open_regions=open_regions,initialize_regions=initialize_regions, **defense))
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


def rewrite_status(document, plan, allowed, campaign_ids=None, effect_types=None, region_reference=None, defense_states=None):
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
            if (planet, effect) not in pairs:
                additions.append({"index": planet, "galacticEffectId": effect})
                pairs.add((planet, effect))
    # Work on copies only: one bad target must never leave a partially changed body.
    result = copy.deepcopy(document)
    next_defense_states = copy.deepcopy(defense_states) if defense_states is not None else {}
    result["planetActiveEffects"] = entries + additions
    changes = len(additions)
    initialize_targets=[t for t in targets if t['initialize_regions']]
    if initialize_targets:
        if not isinstance(region_reference,dict) or region_reference.get('warId')!=document.get('warId') or region_reference.get('layoutVersion')!=document.get('layoutVersion'):
            raise RegionAvailabilityError('缺少当前战争及布局对应的原生分区定义')
        definitions=region_reference.get('planetRegions')
        regions=result.get('planetRegions')
        if not isinstance(definitions,list) or not isinstance(regions,list):
            raise RegionAvailabilityError('原生分区定义或状态列表不兼容')
        for target in initialize_targets:
            native=[r for r in definitions if isinstance(r,dict) and r.get('planetIndex')==target['planet']]
            if not native:
                raise RegionAvailabilityError('所选星球没有原生分区定义')
            seen=set()
            for definition in native:
                index=definition.get('regionIndex');maximum=definition.get('maxHealth')
                if type(index) is not int or index<0 or index in seen or type(maximum) is not int or maximum<=1:
                    raise RegionAvailabilityError('原生分区编号或生命值上限不兼容')
                seen.add(index)
                existing=[r for r in regions if isinstance(r,dict) and r.get('planetIndex')==target['planet'] and r.get('regionIndex')==index]
                if len(existing)>1:
                    raise RegionAvailabilityError('当前战况包含重复的原生分区状态')
                if existing:
                    # Explicit local campaign initialization must also make
                    # existing native regions playable for the selected enemy.
                    # Merely preserving a locked/liberated/stale row leaves
                    # the planet with a campaign but no eligible operations.
                    region=existing[0]
                    for field,value in (('owner',target['campaign_race']),('isAvailable',True)):
                        if region.get(field)!=value:
                            region[field]=value;changes+=1
                    factor=region.get('availabilityFactor')
                    if type(factor) not in (int,float) or not math.isfinite(factor) or factor<=0:
                        region['availabilityFactor']=1;changes+=1
                    health=region.get('health')
                    if type(health) not in (int,float) or not math.isfinite(health) or health<=0 or health>maximum:
                        region['health']=maximum//2;changes+=1
                    continue
                # Experimental local state, not server defaults or persisted war progress.
                regions.append(dict(planetIndex=target['planet'],regionIndex=index,owner=target['campaign_race'],health=maximum//2,players=0,regerPerSecond=0,isAvailable=True,availabilityFactor=1))
                changes+=1
    region_targets={t['planet'] for t in targets if t['open_regions']}
    if region_targets:
        regions=result.get('planetRegions')
        if not isinstance(regions,list):
            raise RegionAvailabilityError('当前战况不包含原生分区，未创建虚构分区')
        found=set()
        for region in regions:
            if not isinstance(region,dict):
                raise RegionAvailabilityError('原生分区结构不兼容')
            if region.get('planetIndex') not in region_targets:
                continue
            if type(region.get('regionIndex')) is not int or type(region.get('isAvailable')) is not bool or type(region.get('availabilityFactor')) not in (int,float) or not math.isfinite(region['availabilityFactor']):
                raise RegionAvailabilityError('原生分区可用性字段不兼容，已保持原样')
            found.add(region['planetIndex'])
            if not region['isAvailable']:
                region['isAvailable']=True;changes+=1
            if region['availabilityFactor']<=0:
                region['availabilityFactor']=1;changes+=1
        if found!=region_targets:
            raise RegionAvailabilityError('所选星球缺少原生分区，已保持原样')
    output_campaign_ids = campaign_ids
    campaign_ids = dict(campaign_ids) if campaign_ids is not None else {}
    used_ids = {c["id"] for c in campaigns} if any(t["campaign"] or t["owner"] for t in targets) else set()
    for target in targets:
        planet = next(p for p in result["planetStatus"] if p.get("index") == target["planet"])
        original_owner = planet.get("owner", 0)
        native_races = {NATIVE_ENEMY_EFFECTS[e['galacticEffectId']] for e in entries if e['index'] == target['planet'] and e['galacticEffectId'] in NATIVE_ENEMY_EFFECTS}
        inferred_race = original_owner if original_owner in (2, 3, 4) else next(iter(native_races)) if len(native_races) == 1 else 1
        requested_race = target['campaign_race'] or (target['owner'] if target['owner'] in (2, 3, 4) else 0)
        if target["owner"] and planet.get("owner") != target["owner"]:
            planet["owner"] = target["owner"]
            changes += 1
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
                current = {"id": candidate, "planetIndex": target["planet"], "type": target["campaign_type"], "count": 1, "race": requested_race or inferred_race}
                result.setdefault("campaigns", []).append(current)
                changes += 1
            elif current.get("type") != target["campaign_type"]:
                current["type"] = target["campaign_type"]
                changes += 1
            if type(current.get('count')) is not int or current['count'] <= 0:
                current['count'] = 1
                changes += 1
            if requested_race and current.get("race") != requested_race:
                current["race"] = requested_race
                changes += 1
            if target['campaign_type'] == 4:
                before = copy.deepcopy(result)
                apply_defense(result, target, current, next_defense_states)
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
            temporary.write_text(json.dumps({"message": message, "ready": self.ready, "router_port": self.api_router.port if self.api_router else 0, "failures": self.failures, "connection": self.connection, "rewrites": self.rewrites, "statuses": self.statuses, "catalog_count": self.catalog_count, "war_id": self.war_id, "applied_plan_digest": self.applied_plan_digest, "updated": time.time()}, ensure_ascii=False), encoding="utf-8")
            os.replace(temporary, target)
        except OSError:
            pass  # Diagnostics must not break forwarding.

    def load(self, loader):
        self.plan_path = Path(os.environ["CPV_WAR_PLAN"])
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
        if request.method=='GET' and request.pretty_host.lower()==HOST and (STATUS.fullmatch(request.path.split('?',1)[0]) or request.path.split('?',1)[0]=="/api/WarSeason/GalacticWarEffects"):
            # Refresh Status and the live effect catalog; authentication is untouched.
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
        with opener.open("https://"+HOST+"/api/WarSeason/"+str(war_id)+"/WarInfo",timeout=8) as reply:
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
                if any(t['initialize_regions'] for t in normalize_targets(self.plan)):
                    raw=response.content
                    if raw is not None and len(raw)<=MAX_BODY:
                        document=json.loads(raw);war_id=int(path.split('/')[3])
                        if not isinstance(document,dict):
                            raise ValueError('战况不是对象')
                        if not isinstance(self.region_reference,dict) or self.region_reference.get('warId')!=war_id or self.region_reference.get('layoutVersion')!=document.get('layoutVersion'):
                            self.region_reference=await asyncio.to_thread(self.fetch_region_reference,war_id)
                            self.region_reference_error=None
            except (ValueError,TypeError,KeyError,OSError) as error:
                self.region_reference_error=type(error).__name__
        self.process_response(flow)

    def process_response(self, flow):
        request, response = flow.request, flow.response
        if request.pretty_host.lower() == HOST:
            self.connection["responses"] += 1
            self.connection["last_status"] = int(response.status_code)
            if response.status_code >= 400:
                self.health("游戏 API 返回 HTTP " + str(int(response.status_code)) + "；未修改此响应")
        if request.method != "GET" or request.pretty_host.lower() != HOST or response.status_code != 200:
            return
        path = request.path.split("?", 1)[0]
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
            if self.allowed is None and any(t["effects"] for t in normalize_targets(self.plan)):
                self.health("尚未获取本次效果目录，战况保持原样；请重新登录游戏")
                return
            region_error = None
            try:
                changed, count = rewrite_status(document, self.plan, self.allowed, self.campaign_ids, self.effect_types,self.region_reference,self.defense_states)
            except RegionAvailabilityError as error:
                # Unsupported experimental regions must not remove the working
                # planet campaigns/effects from this same Status response.
                region_error = str(error)
                fallback = copy.deepcopy(self.plan)
                for target in fallback.get('targets', []):
                    target['open_regions'] = False
                    target['initialize_regions'] = False
                changed, count = rewrite_status(document, fallback, self.allowed, self.campaign_ids, self.effect_types,defense_states=self.defense_states)
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
                'region_error':region_error, 'region_reference_error':self.region_reference_error, 'initialized_region_planets':[t['planet'] for t in normalize_targets(self.plan) if t['initialize_regions']] if not region_error else [], 'plan_digest':self.plan_digest, 'operation_generation_verified':False, 'updated': time.time()})
            self.applied_plan_digest = self.plan_digest
            self.health(("分区实验未应用："+region_error+"；其余战役与效果已应用") if region_error else "方案已应用到本次战况响应；已生成作战和局内效果仍需游戏验证")
        except (ValueError, KeyError, TypeError, UnicodeError, OSError) as error:
            self.health("校验未通过，响应保持原样："+str(error)[:140])


addons = [WarStatusAddon()]
