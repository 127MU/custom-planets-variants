"""Isolated native IPC/Steam bridge smoke. Never trusts a CA or launches the game."""
import argparse, json, os, queue, subprocess, threading, time
from pathlib import Path

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--core',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--runtime',type=Path)
    parser.add_argument('--addon',type=Path)
    args=parser.parse_args()
    profile=args.output.resolve();profile.mkdir(parents=True,exist_ok=True)

    class Core:
        def __init__(self):
            env={**os.environ,'CPV_PROFILE':str(profile)}
            if args.addon:env['CPV_ADDON_FILE']=str(args.addon.resolve())
            self.process=subprocess.Popen([str(args.core.resolve())],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf8',env=env)
            self.messages=queue.Queue();self.id=0
            def read():
                for line in self.process.stdout:
                    try:self.messages.put(json.loads(line))
                    except ValueError:pass
            self.reader=threading.Thread(target=read,daemon=True);self.reader.start()
        def call(self,method,data=None,error=False):
            self.id+=1;self.process.stdin.write(json.dumps({'id':self.id,'method':method,'args':data or {}})+'\n');self.process.stdin.flush()
            response=self.messages.get(timeout=60);assert response['id']==self.id,response
            if error:assert 'error' in response,response;return response['error']
            assert 'error' not in response,response
            return response['result']
        def close(self):
            if self.process.poll() is None:self.call('shutdown');self.process.stdin.close();self.process.wait(timeout=10)
            assert self.process.returncode==0,self.process.stderr.read()

    core=Core()
    try:
        initial=core.call('bootstrap');assert not initial['state']['active'];assert len(initial['catalog']['effects'])==315
        known = next(row for row in initial['catalog']['planets'] if row['id'] == 0)
        planets = core.call('save_planet_catalog', {'warId': 801, 'planets': [{'index': 0}, {'index': 9001}]})
        assert next(row for row in planets if row['id'] == 0) == known
        assert next(row for row in planets if row['id'] == 9001)['englishName'] == 'Planet #9001'
        core.call('save_planet_catalog', {'warId': 801, 'planets': [{'index': 0}, {'index': 0}]}, error=True)
        assert core.call('catalog')['planets'] == planets
        armory = core.call('inventory_preview')
        assert armory == {'enabled': True, 'items': [], 'customization': []}
        armory['items'] = [{'mixId': 2112173638, 'amount': 1, 'isDiscovered': False}]
        armory['unlockAllWeapons'] = True
        assert core.call('inventory_preview', armory) == armory
        core.call('inventory_preview', {**armory, 'unlockAllWeapons': 'true'}, error=True)
        armory_path = profile/'war-proxy/inventory-preview.json'
        armory_path.write_text(json.dumps({**armory, 'remove': [2112173638]}), 'utf8')
        assert core.call('inventory_preview') == armory
        assert core.call('inventory_preview', {**armory, 'remove': [2112173638]}) == armory
        assert 'remove' not in json.loads(armory_path.read_text('utf8'))
        core.call('save_target',{'target':{'planet':64,'effects':[1346,1431],'force_open':True}})
        saved=(profile/'war-targets.json').read_bytes()
        core.call('save_target',{'target':{'planet':-1,'effects':[]}},error=True)
        assert (profile/'war-targets.json').read_bytes()==saved
        core.call('settings',{'language':'en','theme':'dark','material':'liquid'})
        core.call('export',{'path':str(profile/'export.json')})
        core.call('settings',{'diagnostics':True})
        report=core.call('diagnose');assert len(report['checks'])>=5 and not report['state']['active']
        core.call('export_diagnostics',{'path':str(profile/'diagnostics-export.json'),'client':{'language':'en','password':'DO_NOT_EXPORT','last_error':'access_token=SECRET'}})
        exported=(profile/'diagnostics-export.json').read_text('utf8');assert 'DO_NOT_EXPORT' not in exported and '=SECRET' not in exported
        assert json.loads(exported)['client']['language']=='en'

        core.call('remove_target',{'planet':64})
        assert core.call('import',{'path':str(profile/'export.json')})[0]['effects']==[1346,1431]
        launch=core.call('steam_options');assert launch.endswith('" %command%')
        # A normal inactive bridge must preserve the original argument quoting.
        script=profile/'capture_args.py';captured=profile/'arguments.json'
        script.write_text('import json,sys,pathlib\npathlib.Path(sys.argv[1]).write_text(json.dumps(sys.argv[2:],ensure_ascii=False),encoding="utf8")\n','utf8')
        values=['space in argument','literal"quote','trailing\\','中文']
        result=subprocess.run([str(profile/'war-proxy/steam-bridge.exe'),os.sys.executable,str(script),str(captured),*values],timeout=15,capture_output=True)
        assert result.returncode==0,result.stderr
        assert json.loads(captured.read_text('utf8'))==values
        assert not (profile/'war-proxy/steam-proxy.ini').exists()
        core.close();core=Core()
        reloaded=core.call('bootstrap');assert reloaded['settings']['diagnostics'] is True;assert reloaded['settings']['language']=='en';assert reloaded['targets'][0]['effects']==[1346,1431];assert not reloaded['state']['active']
        assert reloaded['targets'][0]['force_open'] is True
        assert reloaded['catalog']['planets'] == planets
        assert core.call('inventory_preview') == armory
        if args.runtime:
            core.call('settings',{'runtime':str(args.runtime.resolve())})
            core.call('prepare_certificate')
            deadline=time.monotonic()+50
            while time.monotonic()<deadline:
                state=core.call('state')
                if not state['preparing']:break
                time.sleep(.25)
            assert state['certificateExists'] and not state['trusted'],state
            core.call('start');deadline=time.monotonic()+50
            while time.monotonic()<deadline:
                state=core.call('state')
                if state['ready']:break
                time.sleep(.25)
            assert state['ready'] and state['active'],state
            assert not state['trusted']
            assert not (profile/'war-proxy/steam-proxy.ini').exists()
            assert not core.call('stop')['active']
        core.close()
        (profile/'result.json').write_text(json.dumps({'ok':True,'ipc':True,'persist':True,'import_export':True,'bridge_quoting':True,'proxy_smoke':bool(args.runtime),'installed_certificate':False,'launched_game':False},indent=2),'utf8')
        print((profile/'result.json').read_text())
    finally:
        if core.process.poll() is None:
            try:core.close()
            except Exception:core.process.kill();core.process.wait(timeout=10)

if __name__ == "__main__":
    main()
