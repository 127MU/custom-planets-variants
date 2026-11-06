"""Offline mitmproxy hook/transform regression. Never opens network listeners."""
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
import os
import tempfile
import asyncio
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("war_status_addon", Path(__file__).resolve().parents[1]/"proxy/war_status_addon.py")
addon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(addon)
PLAN = {"targets": [{"planet": 182, "variant": "test"}], "variants": {"test": [1373, 1386]}}
BASE = {"planetStatus": [{"index": 182}], "planetActiveEffects": [], "unchanged": {"owner": 4}}


def flow(path, document, host=addon.HOST, method="GET"):
    return SimpleNamespace(request=SimpleNamespace(pretty_host=host, path=path, method=method),
                           response=SimpleNamespace(status_code=200, content=json.dumps(document).encode(), headers={"etag": "old"}))


class TestWarStatusAddon(unittest.TestCase):
    def test_attachment_preview_matches_weapon_and_option_in_any_slot(self):
        def preset(weapon, index, slots):
            return {"mixId32": weapon, "index": index, "activeIndex": 2,
                    "slots": slots, "modes": [1, 2, 3, 4]}

        document = {"items": [], "customization": [
            preset(7, 0, [0, 11, 0, 21, 0, 0, 0, 0]),
            preset(7, 1, [0, 0, 0, 11, 0, 0, 0, 0]),
            preset(8, 0, [0, 11, 0, 0, 0, 0, 0, 0]),
        ]}
        plan = {"enabled": True, "items": [], "remove": [], "customization": [],
                "attachmentChanges": [{"weapon": 7, "from": 11, "to": 21},
                                      {"weapon": 7, "from": 21, "to": 31}]}
        preview = addon.rewrite_inventory(document, plan)
        self.assertEqual(preview["customization"], [
            preset(7, 0, [0, 21, 0, 31, 0, 0, 0, 0]),
            preset(7, 1, [0, 0, 0, 21, 0, 0, 0, 0]),
            document["customization"][2],
        ])
        self.assertEqual(document["customization"][0]["slots"][1], 11)

    def test_inventory_preview_uses_only_exact_get_and_preserves_owned_rows(self):
        document = {
            "items": [{"mixId": 1, "amount": 9, "isDiscovered": True},
                      {"mixId": 2, "amount": 1, "isDiscovered": False}],
            "customization": [{"mixId32": 1, "index": 0, "activeIndex": 1,
                               "slots": [0] * 8, "modes": [0] * 4, "extra": True}],
            "limitSettings": {"sample": 12},
        }
        with tempfile.TemporaryDirectory() as directory:
            hook = addon.WarStatusAddon()
            hook.plan_path = Path(directory) / "plan.json"
            config = Path(directory) / "inventory-preview.json"
            plan = {
                "enabled": True,
                "items": [{"mixId": mix_id, "amount": 1, "isDiscovered": False}
                          for mix_id in [1, 3, 3]],
                "remove": [2],
                "customization": [{"mixId32": 1, "index": 0, "activeIndex": 0,
                                   "slots": [1] * 8, "modes": [0] * 4}],
            }
            config.write_text(json.dumps(plan), encoding="utf-8")
            valid = flow(addon.INVENTORY + "?refresh=1", document)
            hook.process_response(valid)
            result = json.loads(valid.response.content)
            self.assertEqual([r["mixId"] for r in result["items"]], [1, 3])
            self.assertEqual(result["items"][0], document["items"][0])
            self.assertEqual(result["customization"][0]["slots"], [1] * 8)
            self.assertTrue(result["customization"][0]["extra"])
            self.assertEqual(result["limitSettings"], document["limitSettings"])
            self.assertEqual(valid.response.headers, {"cache-control": "no-store"})
            ignored = [
                flow(addon.INVENTORY + "/other", document),
                flow(addon.INVENTORY, document, method="PUT"),
                flow(addon.INVENTORY, document, host="example.test"),
            ]
            for sample in ignored:
                hook.process_response(sample)
                self.assertEqual(json.loads(sample.response.content), document)
            plan["enabled"] = False
            config.write_text(json.dumps(plan), encoding="utf-8")
            disabled = flow(addon.INVENTORY, document)
            hook.process_response(disabled)
            self.assertEqual(json.loads(disabled.response.content), document)

    def test_initialize_regions_uses_native_ids_and_preserves_existing_state(self):
        document=dict(BASE,warId=801,layoutVersion=7,planetRegions=[dict(planetIndex=182,regionIndex=3,owner=2,health=19,isAvailable=False,availabilityFactor=0)])
        plan={'targets':[{'planet':182,'effects':[],'campaign':True,'campaign_race':3,'initialize_regions':True}]}
        reference={'warId':801,'layoutVersion':7,'planetRegions':[dict(planetIndex=182,regionIndex=3,maxHealth=100),dict(planetIndex=182,regionIndex=9,maxHealth=600000)]}
        before=json.dumps(document);result,count=addon.rewrite_status(document,plan,set(),region_reference=reference)
        self.assertEqual(result['planetRegions'][0],dict(document['planetRegions'][0],owner=3,isAvailable=True,availabilityFactor=1))
        self.assertEqual(result['planetRegions'][1],dict(planetIndex=182,regionIndex=9,owner=3,health=300000,players=0,regerPerSecond=0,isAvailable=True,availabilityFactor=1))
        self.assertEqual(json.dumps(document),before)
        self.assertEqual(addon.rewrite_status(result,plan,set(),region_reference=reference)[1],0)
        for wrong in (None,dict(reference,warId=800),dict(reference,layoutVersion=6),dict(reference,planetRegions=[]),dict(reference,planetRegions=reference['planetRegions']*2)):
            with self.assertRaises(addon.RegionAvailabilityError):addon.rewrite_status(document,plan,set(),region_reference=wrong)
            self.assertEqual(json.dumps(document),before)

    def test_initialize_reopens_existing_liberated_regions_without_touching_other_planets(self):
        other=dict(planetIndex=10,regionIndex=1,owner=1,health=0,isAvailable=False,availabilityFactor=0)
        document=dict(BASE,warId=801,layoutVersion=7,planetRegions=[
            dict(planetIndex=182,regionIndex=3,owner=1,health=0,isAvailable=False,availabilityFactor=0,players=15),other])
        reference=dict(warId=801,layoutVersion=7,planetRegions=[dict(planetIndex=182,regionIndex=3,maxHealth=100)])
        plan={'targets':[dict(planet=182,effects=[],campaign=True,campaign_race=3,initialize_regions=True)]}
        result,count=addon.rewrite_status(document,plan,set(),region_reference=reference)
        self.assertGreater(count,0)
        self.assertEqual(result['planetRegions'][0],dict(planetIndex=182,regionIndex=3,owner=3,health=50,isAvailable=True,availabilityFactor=1,players=15))
        self.assertEqual(result['planetRegions'][1],other)
        self.assertEqual(document['planetRegions'][0]['health'],0)
        self.assertEqual(addon.rewrite_status(result,plan,set(),region_reference=reference)[1],0)
        plan['targets'][0]['initialize_regions']=False
        unchanged,_=addon.rewrite_status(document,plan,set())
        self.assertEqual(unchanged['planetRegions'],document['planetRegions'])

    def test_initialize_requires_explicit_enemy_and_campaign(self):
        for values in ({'initialize_regions':1},{'initialize_regions':True},{'initialize_regions':True,'campaign':True,'campaign_race':1}):
            with self.assertRaises(ValueError):addon.normalize_targets({'targets':[dict(planet=182,effects=[],**values)]})

    def test_async_region_reference_fetch_is_cached_and_failure_keeps_campaign(self):
        instance=addon.WarStatusAddon();instance.plan={'targets':[{'planet':182,'effects':[],'campaign':True,'campaign_race':3,'initialize_regions':True}]}
        instance.reload_plan=lambda:None
        snapshots={};instance.snapshot=lambda name,data:snapshots.update({name:data})
        document=dict(BASE,warId=801,layoutVersion=7,planetRegions=[])
        reference={'warId':801,'layoutVersion':7,'planetRegions':[dict(planetIndex=182,regionIndex=4,maxHealth=600000)]}
        with patch.object(instance,'fetch_region_reference',return_value=reference) as fetch:
            f=flow('/api/WarSeason/801/Status',document);asyncio.run(instance.response(f))
            self.assertEqual(json.loads(f.response.content)['planetRegions'][0]['regionIndex'],4)
            asyncio.run(instance.response(flow('/api/WarSeason/801/Status',document)))
            self.assertEqual(fetch.call_count,1)
        instance.region_reference=None
        with patch.object(instance,'fetch_region_reference',side_effect=OSError('network')):
            f=flow('/api/WarSeason/801/Status',document);asyncio.run(instance.response(f))
            self.assertFalse(json.loads(f.response.content)['planetRegions'])
            self.assertTrue(json.loads(f.response.content)['campaigns'])
            self.assertEqual(snapshots['campaign-diagnostics.json']['region_reference_error'],'OSError')

    def test_region_failure_keeps_campaign_and_records_reason(self):
        for regions in (None,[],[dict(planetIndex=182,regionIndex=0,isAvailable=1,availabilityFactor=0)]):
            instance=addon.WarStatusAddon();instance.plan={'targets':[{'planet':182,'effects':[],'open_regions':True,'campaign':True,'campaign_race':3}]}
            snapshots={};instance.snapshot=lambda name,data:snapshots.update({name:data})
            document=dict(BASE,campaigns=[],planetRegions=regions)
            f=flow('/api/WarSeason/801/Status',document);instance.process_response(f)
            result=json.loads(f.response.content)
            self.assertEqual(result['campaigns'][0]['planetIndex'],182)
            self.assertEqual(result['planetRegions'],regions)
            self.assertEqual(instance.rewrites,1)
            self.assertTrue(snapshots['campaign-diagnostics.json']['region_error'])
            self.assertEqual(snapshots['campaign-diagnostics.json']['targets'][0]['campaigns'][0]['race'],3)

    def test_open_native_regions_preserves_other_fields_and_is_idempotent(self):
        document=dict(BASE,planetRegions=[
            dict(planetIndex=182,regionIndex=0,isAvailable=False,availabilityFactor=0,owner=1,health=42,settingsHash=123),
            dict(planetIndex=182,regionIndex=1,isAvailable=True,availabilityFactor=0.5,owner=3,health=99),
            dict(planetIndex=260,regionIndex=0,isAvailable=False,availabilityFactor=0)])
        before=json.dumps(document)
        plan={'targets':[{'planet':182,'effects':[],'open_regions':True}]}
        result,count=addon.rewrite_status(document,plan,set())
        self.assertEqual(count,2)
        self.assertEqual(json.dumps(document),before)
        self.assertEqual(result['planetRegions'][0],dict(document['planetRegions'][0],isAvailable=True,availabilityFactor=1))
        self.assertEqual(result['planetRegions'][1:],document['planetRegions'][1:])
        self.assertEqual(addon.rewrite_status(result,plan,set())[1],0)

    def test_open_native_regions_validates_atomically(self):
        plan={'targets':[{'planet':182,'effects':[],'open_regions':True}]}
        valid=dict(planetIndex=182,regionIndex=0,isAvailable=False,availabilityFactor=0)
        for regions in (None,[],[dict(valid,isAvailable=1)],[dict(valid,availabilityFactor=float('inf'))],[dict(valid,regionIndex='0')],[valid,dict(valid,availabilityFactor='0')]):
            document=dict(BASE,planetRegions=regions);before=json.dumps(document)
            with self.assertRaises(ValueError):addon.rewrite_status(document,plan,set())
            self.assertEqual(json.dumps(document),before)
        for flag in ('true',1,None):
            with self.assertRaises(ValueError):addon.normalize_targets({'targets':[{'planet':182,'open_regions':flag}]})

    def test_region_diagnostics_report_before_and_after(self):
        instance=addon.WarStatusAddon();instance.plan={'targets':[{'planet':182,'effects':[],'open_regions':True}]}
        snapshots={};instance.snapshot=lambda name,data:snapshots.update({name:data})
        instance.process_response(flow('/api/WarSeason/801/Status',dict(BASE,planetRegions=[dict(planetIndex=182,regionIndex=0,isAvailable=False,availabilityFactor=0,health=42,secret='excluded')])))
        target=snapshots['campaign-diagnostics.json']['targets'][0]
        self.assertFalse(target['server_regions'][0]['isAvailable'])
        self.assertTrue(target['output_regions'][0]['isAvailable'])
        self.assertEqual(target['output_regions'][0]['health'],42)
        self.assertNotIn('secret',json.dumps(target))

    def test_war_info_region_capture_never_changes_response(self):
        instance=addon.WarStatusAddon();seen={};instance.snapshot=lambda name,data:seen.update({name:data})
        f=flow('/api/WarSeason/801/WarInfo',{'planetRegions':[{'planetIndex':0,'regionIndex':0,'settingsHash':4196558004,'unknownSecret':'do-not-copy'}]})
        original=f.response.content;instance.process_response(f)
        self.assertEqual(f.response.content,original)
        self.assertEqual(instance.rewrites,0)
        self.assertEqual(seen['planet-region-definitions.json']['regions'][0]['settingsHash'],4196558004)
        self.assertNotIn('do-not-copy',json.dumps(seen))

    def test_campaign_diagnostics_distinguish_input_from_output(self):
        instance=addon.WarStatusAddon();instance.plan={'targets':[{'planet':260,'effects':[],'campaign':True,'campaign_race':3}]}
        snapshots={};instance.snapshot=lambda name,data:snapshots.update({name:data})
        instance.process_response(flow('/api/WarSeason/801/Status',{'planetStatus':[{'index':260,'owner':1}],'planetActiveEffects':[],'campaigns':[]}))
        report=snapshots['campaign-diagnostics.json'];target=report['targets'][0]
        self.assertFalse(target['server_campaigns'])
        self.assertEqual(target['campaigns'][0]['race'],3)
        self.assertFalse(report['operation_generation_verified'])
        instance.process_response(flow('/api/WarSeason/801/Status',{'planetStatus':[{'index':260,'owner':1}],'planetActiveEffects':[],'campaigns':[],'planetEvents':None,'jointOperations':None}))
        self.assertEqual(instance.rewrites,2)
        self.assertFalse(snapshots['campaign-diagnostics.json']['targets'][0]['server_events'])

    def ready(self):
        instance = addon.WarStatusAddon()
        instance.plan = PLAN
        instance.process_response(flow("/api/WarSeason/GalacticWarEffects", {"galacticEffects": [{"id": 1373}, {"id": 1386}]}))
        return instance

    def test_add_only_and_deduplicate(self):
        original = json.dumps(BASE)
        changed, count = addon.rewrite_status(BASE, PLAN, {1373, 1386})
        self.assertEqual(count, 2)
        self.assertEqual(json.dumps(BASE), original)
        self.assertEqual(changed["unchanged"], BASE["unchanged"])
        self.assertEqual(addon.rewrite_status(changed, PLAN, {1373, 1386})[1], 0)

    def test_unknown_effect_is_atomic(self):
        with self.assertRaises(ValueError):
            addon.rewrite_status(BASE, PLAN, {1373})
        self.assertEqual(BASE["planetActiveEffects"], [])

    def test_bad_schema(self):
        for document in ({}, [], dict(BASE, planetActiveEffects=[{}]), dict(BASE, planetStatus=[])):
            with self.assertRaises(ValueError):
                addon.rewrite_status(document, PLAN, {1373, 1386})

    def test_new_war_and_query(self):
        instance = self.ready()
        f = flow("/api/WarSeason/9999/Status?x=1", BASE)
        instance.process_response(f)
        self.assertEqual(instance.rewrites, 1)
        self.assertEqual(len(json.loads(f.response.content)["planetActiveEffects"]), 2)
        self.assertNotIn("etag", f.response.headers)

    def test_never_rewrites_requests_or_other_paths(self):
        instance = self.ready()
        for path, host, method in [("/api/Account", addon.HOST, "GET"), ("/api/WarSeason/801/Status", "example.com", "GET"), ("/api/WarSeason/801/Status", addon.HOST, "POST")]:
            f = flow(path, BASE, host, method)
            original = f.response.content
            instance.process_response(f)
            self.assertEqual(f.response.content, original)
        self.assertEqual(instance.rewrites, 0)

    def test_requires_fresh_catalog(self):
        instance = addon.WarStatusAddon()
        instance.plan = PLAN
        f = flow("/api/WarSeason/801/Status", BASE)
        original = f.response.content
        instance.process_response(f)
        self.assertEqual(f.response.content, original)

    def test_rejects_broken_new_catalog(self):
        instance = self.ready()
        instance.process_response(flow("/api/WarSeason/GalacticWarEffects", {"galacticEffects": [{}]}))
        self.assertIsNone(instance.allowed)

    def test_malformed_status_fails_open(self):
        instance = self.ready()
        f = flow("/api/WarSeason/801/Status", BASE)
        f.response.content = b"not json"
        instance.process_response(f)
        self.assertEqual(f.response.content, b"not json")
        self.assertEqual(instance.rewrites, 0)

    def test_multiple_planets_and_disabled(self):
        plan = {"targets": [{"planet": 182, "effects": [1373]}, {"planet": 93, "effects": [1386]}, {"planet": 999, "effects": [999], "enabled": False}]}
        original = dict(BASE, planetStatus=[{"index": 182}, {"index": 93}])
        changed, count = addon.rewrite_status(original, plan, {1373, 1386})
        self.assertEqual(count, 2)
        self.assertEqual(changed["planetActiveEffects"], [{"index": 182, "galacticEffectId": 1373}, {"index": 93, "galacticEffectId": 1386}])
        plan["targets"][0]["enabled"] = False
        changed, count = addon.rewrite_status(original, plan, {1373, 1386})
        self.assertEqual(count, 1)
        self.assertEqual(changed["planetActiveEffects"][0]["index"], 93)

    def test_campaign_and_owner_without_effect_catalog(self):
        plan = {"targets": [{"planet": 182, "effects": [], "owner": 3, "campaign": True, "campaign_type": 2}]}
        original = dict(BASE, planetStatus=[{"index": 182, "owner": 4}], campaigns=[{"id": 10, "planetIndex": 93, "type": 0, "count": 4}])
        ids = {}
        changed, count = addon.rewrite_status(original, plan, None, ids)
        self.assertEqual(changed["planetStatus"][0]["owner"], 3)
        new = changed["campaigns"][-1]
        self.assertEqual((new["id"], new["planetIndex"], new["type"], new["race"]), (11, 182, 2, 3))
        self.assertEqual(addon.rewrite_status(original, plan, None, ids)[0]["campaigns"][-1]["id"], 11)
        self.assertEqual(original["planetStatus"][0]["owner"], 4)
        self.assertEqual(len(original["campaigns"]), 1)
        self.assertEqual(addon.rewrite_status(changed, plan, None, ids)[1], 0)

    def test_campaign_existing_and_collision(self):
        plan = {"targets": [{"planet": 182, "effects": [], "campaign": True, "campaign_type": 3}]}
        original = dict(BASE, campaigns=[{"id": 90, "planetIndex": 182, "type": 0, "count": 4, "keep": "preserved"}])
        changed, _ = addon.rewrite_status(original, plan, None)
        self.assertEqual(changed["campaigns"], [{"id": 90, "planetIndex": 182, "type": 3, "count": 4, "keep": "preserved"}])
        original["campaigns"][0]["planetIndex"] = 93
        changed, _ = addon.rewrite_status(original, plan, None, {182: 90})
        self.assertEqual(changed["campaigns"][-1]["id"], 91)

    def test_cyberstan_native_bots_are_not_replaced_with_terminids(self):
        original={'planetStatus':[{'index':260,'owner':1}], 'planetActiveEffects':[{'index':260,'galacticEffectId':1361}], 'campaigns':[]}
        plan={'targets':[{'planet':260,'effects':[],'owner':1,'campaign':True}]}
        changed,_=addon.rewrite_status(original,plan,None)
        self.assertEqual(changed['campaigns'][0]['race'],3)
        self.assertEqual(changed['planetStatus'][0]['owner'],1)
        # Adding a cross-faction effect must not change native inference.
        plan['targets'][0]['effects']=[1373]
        changed,_=addon.rewrite_status(original,plan,{1373})
        self.assertEqual(changed['campaigns'][0]['race'],3)
        plan['targets'][0]['campaign_race']=4
        changed,_=addon.rewrite_status(original,plan,{1373})
        self.assertEqual(changed['campaigns'][0]['race'],4)
        self.assertEqual(addon.rewrite_status(changed,plan,{1373})[1],0)
        self.assertFalse(original['campaigns'])

    def test_owner_change_keeps_original_enemy_for_new_campaign(self):
        original={'planetStatus':[{'index':93,'owner':4}], 'planetActiveEffects':[], 'campaigns':[]}
        plan={'targets':[{'planet':93,'effects':[],'owner':1,'campaign':True}]}
        changed,_=addon.rewrite_status(original,plan,None)
        self.assertEqual(changed['campaigns'][0]['race'],4)
        original['planetStatus'][0]['owner']=1
        changed,_=addon.rewrite_status(original,plan,None)
        self.assertEqual(changed['campaigns'][0]['race'],1)

    def test_owner_without_opening_campaign(self):
        plan={"targets":[{"planet":182,"effects":[],"owner":3}]}
        original=dict(BASE,campaigns=[{"id":90,"planetIndex":182,"type":2,"count":4,"race":4}])
        changed,_=addon.rewrite_status(original,plan,None)
        self.assertEqual(len(changed["campaigns"]),1)
        self.assertEqual(changed["campaigns"][0],{"id":90,"planetIndex":182,"type":2,"count":4,"race":3})

    def defense_fixture(self):
        original = dict(BASE, time=1000, planetStatus=[{'index':156,'owner':3},{'index':157,'owner':3}],
                        campaigns=[], planetAttacks=[], planetEvents=[], jointOperations=[])
        plan = {'targets':[{'planet':156,'effects':[],'campaign':True,'campaign_type':4,
                            'owner':1,'campaign_race':3,'defense_source':157}]}
        return original, plan

    def test_defense_recipe_links_and_stable_clock(self):
        original, plan = self.defense_fixture()
        ids, states = {}, {}
        changed, count = addon.rewrite_status(original, plan, None, ids, defense_states=states)
        self.assertGreater(count, 0)
        campaign, event, joint = changed['campaigns'][0], changed['planetEvents'][0], changed['jointOperations'][0]
        self.assertEqual(changed['planetStatus'][0]['owner'], 1)
        self.assertEqual(changed['planetAttacks'], [{'source':157,'target':156}])
        self.assertEqual((campaign['type'],campaign['count'],campaign['race']), (4,38,3))
        self.assertEqual(event['campaignId'], campaign['id'])
        self.assertEqual(event['jointOperationIds'], [joint['id']])
        self.assertEqual(event['id'], joint['id'])
        self.assertEqual(event['health'], 990000)
        self.assertEqual(event['maxHealth'], 1000000)
        self.assertEqual(event['expireTime']-event['startTime'], 48*3600)
        self.assertEqual(addon.rewrite_status(changed, plan, None, ids, defense_states=states)[1], 0)
        later = dict(original,time=2000)
        again,_ = addon.rewrite_status(later,plan,None,ids,defense_states=states)
        self.assertEqual(again['planetEvents'][0], event)
        self.assertFalse(original['planetEvents'])

    def test_defense_invalid_source_and_schema_are_atomic(self):
        import copy
        for bad in ('source','time','schema'):
            original,plan=self.defense_fixture()
            if bad=='source': original['planetStatus'][1]['owner']=2
            if bad=='time': original['time']=float('nan')
            if bad=='schema': original['jointOperations']={}
            before=copy.deepcopy(original)
            states={}
            ids={}
            with self.assertRaises(ValueError):
                addon.rewrite_status(original,plan,None,ids,defense_states=states)
            self.assertEqual(original['campaigns'],before['campaigns'])
            self.assertEqual(original['planetStatus'],before['planetStatus'])
            self.assertEqual(states,{})
            self.assertEqual(ids,{})

    def test_defense_source_owner_conflict_rejected_regardless_of_order(self):
        original,plan=self.defense_fixture()
        plan['targets'].append({'planet':157,'effects':[],'owner':2})
        for targets in (plan['targets'],list(reversed(plan['targets']))):
            with self.assertRaises(ValueError):
                addon.rewrite_status(original,{'targets':targets},None)

    def test_defense_proxy_hook_and_disabled_plan(self):
        original,plan=self.defense_fixture()
        instance=self.ready();instance.plan=plan
        f=flow('/api/WarSeason/801/Status',original)
        instance.process_response(f)
        changed=json.loads(f.response.content)
        self.assertEqual(changed['campaigns'][0]['type'],4)
        self.assertEqual(len(changed['jointOperations']),1)
        plan['targets'][0]['enabled']=False
        untouched=flow('/api/WarSeason/801/Status',original)
        instance.process_response(untouched)
        self.assertEqual(json.loads(untouched.response.content),original)

    def test_defense_multiple_targets_avoid_event_id_collisions(self):
        original,plan=self.defense_fixture()
        original['planetStatus'].append({'index':158,'owner':1})
        plan['targets'].append(dict(plan['targets'][0],planet=158,defense_level=38,defense_hours=24))
        original['planetEvents']=[{'id':9999,'planetIndex':9,'eventType':2}]
        original['jointOperations']=[{'id':10000,'planetIndex':8}]
        changed,_=addon.rewrite_status(original,plan,None)
        events=changed['planetEvents'][1:]
        self.assertEqual(len({e['id'] for e in events}),2)
        self.assertTrue(all(e['id']>10000 for e in events))
        self.assertEqual(events[1]['maxHealth'],1900000)
        self.assertEqual(events[1]['expireTime']-events[1]['startTime'],24*3600)
        self.assertEqual(changed['planetEvents'][0],original['planetEvents'][0])

    def test_bad_plan_rejected(self):
        for targets in ([{"planet": 182, "effects": [True]}], [{"planet": 182, "effects": [], "owner": 9}], [{"planet": 182, "effects": [], "campaign_type": 4}], [{"planet": 182, "effects": []}]*2):
            with self.assertRaises(ValueError):
                addon.normalize_targets({"targets": targets})

    def test_verified_effect_pair_is_written_with_campaign(self):
        instance = self.ready()
        instance.plan = {'targets':[{'planet':182,'effects':[1308],'campaign':True,'campaign_type':0,'owner':2}]}
        instance.process_response(flow('/api/WarSeason/GalacticWarEffects', {'galacticEffects':[
            {'id':1307,'effectType':40},{'id':1308,'effectType':71}]}))
        f=flow('/api/WarSeason/801/Status',dict(BASE,campaigns=[]))
        instance.process_response(f)
        result=json.loads(f.response.content)
        self.assertEqual({e['galacticEffectId'] for e in result['planetActiveEffects']},{1307,1308})
        self.assertEqual(result['campaigns'][0]['planetIndex'],182)
        self.assertEqual(result['campaigns'][0]['type'],0)
        self.assertGreater(result['campaigns'][0]['count'],0)
        self.assertEqual(instance.plan['targets'][0]['effects'],[1308])

    def test_pair_requires_both_ids_and_verified_types(self):
        plan={'targets':[{'planet':182,'effects':[1308]}]}
        for allowed,types in [({1308},{1308:71}),({1307,1308},{1307:72,1308:71})]:
            result,_=addon.rewrite_status(BASE,plan,allowed,effect_types=types)
            self.assertEqual(result['planetActiveEffects'],[{'index':182,'galacticEffectId':1308}])

    def test_opening_zero_count_campaign(self):
        plan={'targets':[{'planet':182,'effects':[],'campaign':True}]}
        original=dict(BASE,campaigns=[{'id':10,'planetIndex':182,'type':0,'count':0}])
        result,count=addon.rewrite_status(original,plan,None)
        self.assertEqual(result['campaigns'][0]['count'],1)
        self.assertGreater(count,0)
        self.assertEqual(original['campaigns'][0]['count'],0)

    def test_status_and_catalog_cache_validators_are_removed(self):
        instance=addon.WarStatusAddon()
        f=flow('/api/WarSeason/801/Status',BASE)
        f.request.headers={'if-none-match':'old','if-modified-since':'old','authorization':'keep'}
        instance.request(f)
        self.assertEqual(f.request.headers,{'authorization':'keep','cache-control':'no-cache'})
        f.request.path='/api/WarSeason/GalacticWarEffects'
        f.request.headers={'if-none-match':'old','if-modified-since':'old','authorization':'keep'}
        instance.request(f)
        self.assertEqual(f.request.headers,{'authorization':'keep','cache-control':'no-cache'})
        f.request.path='/api/Account'
        f.request.headers={'if-none-match':'keep','authorization':'keep'}
        instance.request(f)
        self.assertEqual(f.request.headers,{'if-none-match':'keep','authorization':'keep'})

    def test_observe_only(self):
        result, count = addon.rewrite_status(BASE, {"targets": []}, None)
        self.assertIs(result, BASE)
        self.assertEqual(count, 0)

    def test_ambiguous_catalog_never_grants_permission(self):
        for rows in ([{'id':1373,'effectType':71},{'id':1373,'effectType':40}],
                     [{'id':0,'effectType':71}], [{'id':1373,'effectType':True}],
                     [{'id':1373,'effectType':-1}]):
            instance=self.ready()
            instance.process_response(flow('/api/WarSeason/GalacticWarEffects',{'galacticEffects':rows}))
            self.assertIsNone(instance.allowed)
            self.assertEqual(instance.effect_types,{})

    def test_bad_catalog_cannot_reuse_previous(self):
        instance = self.ready()
        f = flow("/api/WarSeason/GalacticWarEffects", {})
        f.response.content = b"bad json"
        instance.process_response(f)
        self.assertIsNone(instance.allowed)

    def test_live_reload_and_private_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);p=root/"plan.json"
            config={"schema":2,"targets":[{"planet":182,"effects":[1373]}],"health_path":str(root/"health.json")}
            p.write_text(json.dumps(config),encoding="utf8")
            instance=addon.WarStatusAddon()
            with patch.dict(os.environ,{"CPV_WAR_PLAN":str(p)}):instance.load(None)
            catalog=flow("/api/WarSeason/GalacticWarEffects",{"galacticEffects":[{"id":1373,"effectType":71,"accountId":"must-not-cache","values":["must-not-cache"]},{"id":1386,"effectType":71}]})
            instance.process_response(catalog)
            status=flow("/api/WarSeason/801/Status",dict(BASE,accountId="must-not-cache"))
            instance.process_response(status)
            self.assertEqual(json.loads(status.response.content)["planetActiveEffects"][0]["galacticEffectId"],1373)
            config["targets"][0]["effects"]=[1386]
            p.write_text(json.dumps(config),encoding="utf8");stamp=instance.plan_stamp+1000000000;os.utime(p,ns=(stamp,stamp))
            status=flow("/api/WarSeason/801/Status",BASE);instance.process_response(status)
            self.assertEqual(json.loads(status.response.content)["planetActiveEffects"][0]["galacticEffectId"],1386)
            for name in ("catalog.json","planets.json","health.json"):
                self.assertNotIn("must-not-cache",(root/name).read_text("utf8"))

    def test_disabling_live_target_stops_modification(self):
        instance=self.ready()
        instance.plan={"schema":2,"targets":[{"planet":182,"effects":[1373],"enabled":False}]}
        f=flow("/api/WarSeason/801/Status",BASE);original=f.response.content;instance.process_response(f)
        self.assertEqual(f.response.content,original)

    def test_live_ack_waits_for_successful_status_even_with_same_mtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);path=root/'plan.json'
            config={'targets':[{'planet':182,'effects':[1373]}],'health_path':str(root/'health.json')}
            path.write_text(json.dumps(config),encoding='utf8')
            instance=addon.WarStatusAddon()
            with patch.dict(os.environ,{'CPV_WAR_PLAN':str(path)}):instance.load(None)
            instance.process_response(flow('/api/WarSeason/GalacticWarEffects',{'galacticEffects':[{'id':1373},{'id':1386}]}))
            instance.process_response(flow('/api/WarSeason/801/Status',BASE))
            old=instance.applied_plan_digest
            stamp=instance.plan_stamp
            config['targets'][0]['effects']=[1386]
            path.write_text(json.dumps(config),encoding='utf8');os.utime(path,ns=(stamp,stamp))
            instance.tick()
            self.assertNotEqual(instance.plan_digest,old)
            self.assertEqual(instance.applied_plan_digest,old)
            instance.process_response(flow('/api/WarSeason/801/Status',{}))
            self.assertEqual(instance.applied_plan_digest,old)
            instance.process_response(flow('/api/WarSeason/801/Status',BASE))
            self.assertEqual(instance.applied_plan_digest,instance.plan_digest)

    def test_tls_diagnostics_do_not_log_credentials(self):
        instance=addon.WarStatusAddon()
        data=SimpleNamespace(context=SimpleNamespace(client=SimpleNamespace(sni=addon.HOST),server=SimpleNamespace(sni=addon.HOST)))
        instance.tls_failed_client(data);instance.tls_failed_server(data)
        self.assertEqual(instance.failures["client_tls"],1)
        self.assertEqual(instance.failures["server_tls"],1)
        other=SimpleNamespace(context=SimpleNamespace(client=SimpleNamespace(sni="example.com"),server=SimpleNamespace(sni="example.com")))
        instance.tls_failed_client(other)
        self.assertEqual(instance.failures["client_tls"],1)
        self.assertFalse(instance.ready)

    def test_connection_diagnostics_only_keep_categories(self):
        instance=addon.WarStatusAddon()
        data=SimpleNamespace(context=SimpleNamespace(client=SimpleNamespace(sni=addon.HOST,error="unknown ca https://secret:password@example.com/private"),server=SimpleNamespace(sni=addon.HOST)))
        instance.tls_failed_client(data)
        self.assertEqual(instance.connection['failure_kind'],'证书信任失败')
        self.assertNotIn('password',json.dumps(instance.connection))
        instance.tls_established_client(data);instance.tls_established_server(data)
        self.assertEqual(instance.connection['client_tls'],1)
        self.assertEqual(instance.connection['server_tls'],1)

    def test_http_failure_categories_hide_url_and_credentials(self):
        instance=addon.WarStatusAddon()
        failed=SimpleNamespace(request=SimpleNamespace(pretty_host=addon.HOST,method='GET',path='/api/WarSeason/801/Status?token=secret',http_version='HTTP/2'),error=SimpleNamespace(msg='HTTP/2 stream reset https://private:secret@example.com'))
        instance.error(failed)
        self.assertEqual(instance.connection['failure_kind'],'HTTP/2 流失败')
        self.assertEqual(instance.connection['failed_endpoint'],'战况接口')
        self.assertNotIn('secret',json.dumps(instance.connection))

    def test_api_router_bypasses_every_other_destination(self):
        import socket
        import socketserver
        import threading
        seen=[]
        class Echo(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.settimeout(3)
                data=self.request.recv(16384);seen.append(data)
                self.request.sendall(data)
        class Server(socketserver.ThreadingTCPServer):
            daemon_threads=True
        with Server(('127.0.0.1',0),Echo) as direct, Server(('127.0.0.1',0),Echo) as core:
            threads=[threading.Thread(target=s.serve_forever,daemon=True) for s in (direct,core)]
            for t in threads:t.start()
            router=addon.ApiOnlyRouter(core.server_address[1])
            try:
                with socket.create_connection(('127.0.0.1',router.port),timeout=3) as client:
                    client.sendall(('CONNECT 127.0.0.1:%s HTTP/1.1\r\n\r\n'%direct.server_address[1]).encode())
                    self.assertIn(b'200',client.recv(4096))
                    client.sendall(b'end-to-end-data');self.assertEqual(client.recv(4096),b'end-to-end-data')
                self.assertEqual(seen,[b'end-to-end-data'])
                with socket.create_connection(('127.0.0.1',router.port),timeout=3) as client:
                    client.sendall(('CONNECT '+addon.HOST+':443 HTTP/1.1\r\nProxy-Authorization: secret\r\n\r\n').encode())
                    data=client.recv(4096)
                    self.assertIn(addon.HOST.encode(),data);self.assertNotIn(b'secret',data)
                self.assertEqual(len(seen),2)
                with socket.create_connection(('127.0.0.1',router.port),timeout=3) as client:
                    client.sendall(('GET http://127.0.0.1:%s/update?q=1 HTTP/1.1\r\nHost: localhost\r\nProxy-Authorization: secret\r\n\r\n'%direct.server_address[1]).encode())
                    data=client.recv(4096)
                    self.assertTrue(data.startswith(b'GET /update?q=1 HTTP/1.1\r\n'))
                    self.assertNotIn(b'secret',data)
                self.assertEqual(len(seen),3)
            finally:
                router.close()
                for s in (direct,core):s.shutdown()

    def test_loaded_is_not_capture_ready(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);p=root/"plan.json";p.write_text(json.dumps({"targets":[],"health_path":str(root/"health.json")}),encoding="utf8")
            instance=addon.WarStatusAddon()
            with patch.dict(os.environ,{"CPV_WAR_PLAN":str(p)}):instance.load(None)
            self.assertFalse(json.loads((root/"health.json").read_text("utf8"))["ready"])


if __name__ == "__main__":
    unittest.main()
