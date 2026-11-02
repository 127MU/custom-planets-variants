#![cfg_attr(all(windows, not(test)), windows_subsystem = "windows")]
mod diagnostics;
mod platform;
use anyhow::{Context, Result, bail, ensure};
use cpv_core::*;
use serde_json::{Value, json};
use std::{
    fs,
    io::{self, BufRead, Write},
    net::TcpListener,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
struct Host {
    profile: PathBuf,
    _profile_lock: fs::File,
    settings: Value,
    targets: Value,
    child: Option<Child>,
    job: Option<platform::Job>,
    session: f64,
    preparing: bool,
    status: String,
    catalog: Value,
    catalog_stamp: Option<SystemTime>,
    planet_stamp: Option<SystemTime>,
}
impl Host {
    fn new(profile: PathBuf) -> Result<Self> {
        fs::create_dir_all(&profile)?;
        let mut options = fs::OpenOptions::new();
        options.read(true).write(true).create(true);
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            options.share_mode(0);
        }
        let profile_lock = options.open(profile.join("cpv-core.lock")).map_err(|e| {
            anyhow::anyhow!("配置目录已被使用或不可写 / Profile in use or not writable: {e}")
        })?;
        let settings_path = profile.join("cpv-settings.json");
        let mut settings = if settings_path.exists() {
            read_json(&settings_path)?
        } else {
            json!({"language":"zh","theme":"light","material":"frosted","opacity":0.76,"accent":0,"useSystemProxy":false})
        };
        if settings.is_object() && std::env::var("CPV_DIAGNOSTICS").ok().as_deref() == Some("1") {
            settings["diagnostics"] = json!(true);
        }
        ensure!(
            settings.is_object(),
            "设置文件无效，原文件已保留 / Invalid settings document; original file retained"
        );
        if let Some(v) = settings.get("language") {
            ensure!(v == "zh" || v == "en", "Invalid language setting");
        }
        if let Some(v) = settings.get("theme") {
            ensure!(
                v == "light" || v == "dark" || v == "system",
                "Invalid theme setting"
            );
        }
        if let Some(v) = settings.get("material") {
            ensure!(
                v == "solid" || v == "frosted" || v == "liquid",
                "Invalid material setting"
            );
        }
        if let Some(v) = settings.get("opacity") {
            ensure!(
                v.as_f64().is_some_and(|n| (0.2..=1.).contains(&n)),
                "Invalid opacity setting"
            );
        }
        if let Some(v) = settings.get("accent") {
            integer(v, 0, 3)?;
        }
        if let Some(v) = settings.get("useSystemProxy") {
            ensure!(v.is_boolean(), "Invalid proxy setting");
        }
        if let Some(v) = settings.get("runtime") {
            ensure!(v.is_string(), "Invalid runtime setting");
        }
        if let Some(v) = settings.get("diagnostics") {
            ensure!(v.is_boolean(), "Invalid diagnostics setting");
        }
        let path = profile.join("war-targets.json");
        let targets = if path.exists() {
            import_document(read_json(&path)?)?
        } else {
            json!([])
        };
        let catalog = catalog(&profile)?;
        Ok(Self {
            profile,
            _profile_lock: profile_lock,
            settings,
            targets,
            child: None,
            job: None,
            session: 0.,
            preparing: false,
            status: "就绪 / Ready".into(),
            catalog,
            catalog_stamp: None,
            planet_stamp: None,
        })
    }
    fn root(&self) -> PathBuf {
        self.profile.join("war-proxy")
    }
    fn cert(&self) -> PathBuf {
        self.root().join("ca/mitmproxy-ca-cert.cer")
    }
    fn persist(&mut self, targets: Value) -> Result<Value> {
        let validated = validate_targets(&targets)?;
        let path = self.profile.join("war-targets.json");
        if path.exists() {
            atomic_write(
                &self.profile.join("war-targets.backup.json"),
                &fs::read(&path)?,
            )?;
        }
        write_json(&path, &json!({"schema":2,"targets":validated}))?;
        self.targets = validated;
        if self.child.is_some() && !self.preparing {
            self.plan(false)?;
        }
        self.status =
            "方案已保存，等待游戏刷新战况 / Saved; waiting for game status refresh".into();
        Ok(self.targets.clone())
    }
    fn plan(&self, prepare: bool) -> Result<()> {
        write_json(
            &self.root().join("plan.json"),
            &json!({"schema":2,"targets":if prepare {json!([])}else{self.targets.clone()},"health_path":self.root().join("health.json")}),
        )
    }
    fn runtime(&self) -> Result<PathBuf> {
        let bin = std::env::current_exe()?
            .parent()
            .unwrap()
            .join("mitmproxy/python.exe");
        let p = self.settings["runtime"]
            .as_str()
            .map(PathBuf::from)
            .unwrap_or(bin);
        ensure!(
            p.is_file() && p.with_file_name("proxy_main.py").is_file(),
            "代理运行时不完整，请选择配套 python.exe / Proxy runtime missing"
        );
        Ok(p)
    }
    fn start(&mut self, prepare: bool) -> Result<Value> {
        self.poll()?;
        ensure!(
            self.child.is_none(),
            "请先停止当前代理 / Stop the active proxy first"
        );
        let runtime = self.runtime()?;
        let root = self.root();
        fs::create_dir_all(root.join("tmp"))?;
        fs::create_dir_all(root.join("ca"))?;
        // An exclusive file handle prevents independent frontends from sharing a live profile.
        let probe = TcpListener::bind(("127.0.0.1", 0))?;
        let port = probe.local_addr()?.port();
        drop(probe);
        let addon = std::env::var_os("CPV_ADDON_FILE")
            .map(PathBuf::from)
            .unwrap_or(
                std::env::current_exe()?
                    .parent()
                    .context("Missing application directory")?
                    .join("proxy/war_status_addon.py"),
            );
        let addon = verified_addon(&addon)?;
        atomic_write(&root.join("addon.py"), &addon)?;
        self.plan(prepare)?;
        for name in ["health.json", "stop.request", "steam-proxy.ini"] {
            let _ = fs::remove_file(root.join(name));
        }
        let mode = if !prepare && self.settings["useSystemProxy"] == true {
            platform::upstream()?
                .map(|p| format!("upstream:{p}@127.0.0.1:{port}"))
                .unwrap_or(format!("regular@127.0.0.1:{port}"))
        } else {
            format!("regular@127.0.0.1:{port}")
        };
        let mut c = Command::new(&runtime);
        c.args(["-I"])
            .arg(runtime.with_file_name("proxy_main.py"))
            .args([
                "--mode",
                &mode,
                "--allow-hosts",
                r"^api\.live\.prod\.thehelldiversgame\.com(:443)?$",
                "--set",
            ])
            .arg(format!("confdir={}", root.join("ca").display()))
            .args([
                "--set",
                "flow_detail=0",
                "--set",
                "connection_strategy=lazy",
                "--set",
                "upstream_cert=false",
                "--set",
                "http2=false",
                "--quiet",
                "-s",
            ])
            .arg(root.join("addon.py"));
        c.current_dir(&root)
            .env("CPV_WAR_PLAN", root.join("plan.json"))
            .env("CPV_PREPARE_CA", if prepare { "1" } else { "0" })
            .env("TEMP", root.join("tmp"))
            .env("TMP", root.join("tmp"))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        if !prepare {
            c.env("CPV_WAR_MITM_PORT", port.to_string());
        }
        let mut child = platform::hidden(&mut c).spawn()?;
        let job = match platform::Job::new(&child) {
            Ok(j) => j,
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(e);
            }
        };
        self.child = Some(child);
        self.job = Some(job);
        self.session = now();
        self.preparing = prepare;
        self.status = "正在启动 / Starting".into();
        self.poll()
    }
    fn stop(&mut self) {
        let _ = fs::remove_file(self.root().join("steam-proxy.ini"));
        let _ = atomic_write(&self.root().join("stop.request"), b"stop");
        if let Some(mut child) = self.child.take() {
            for _ in 0..25 {
                if matches!(child.try_wait(), Ok(Some(_))) {
                    break;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            if matches!(child.try_wait(), Ok(None)) {
                let _ = child.kill();
            }
            let _ = child.wait();
        }
        self.job = None;
        self.preparing = false;
        self.status = "代理已停止，请重启游戏 / Proxy stopped; restart the game".into();
    }
    fn poll(&mut self) -> Result<Value> {
        let exited = if let Some(c) = self.child.as_mut() {
            c.try_wait()?.is_some()
        } else {
            false
        };
        if exited {
            self.child = None;
            self.job = None;
            let _ = fs::remove_file(self.root().join("steam-proxy.ini"));
            self.status = if self.preparing && self.cert().exists() {
                "隔离证书已生成，尚未安装信任 / Certificate generated, not trusted"
            } else {
                "代理已退出 / Proxy exited"
            }
            .into();
            self.preparing = false;
        }
        let mut health = read_json(&self.root().join("health.json")).unwrap_or(json!({}));
        let fresh = self.child.is_some()
            && health["updated"]
                .as_f64()
                .is_some_and(|n| n >= self.session && n <= now() + 5. && now() - n <= 15.);
        let ready = fresh && health["ready"] == true && !self.preparing;
        if ready {
            self.status =
                "代理就绪，等待游戏刷新战况 / Proxy ready; waiting for game status refresh".into();
        }
        if !fresh {
            health = json!({});
        }
        let trusted = platform::trusted(&self.cert());
        if ready && trusted {
            if let Some(port) = health["router_port"]
                .as_u64()
                .filter(|p| *p > 0 && *p < 65536)
            {
                let child = self.child.as_ref().unwrap();
                let pid = child.id();
                let started = platform::process_started(pid)?;
                let data = format!("[proxy]\r\nport={port}\r\npid={pid}\r\nstarted={started}\r\n");
                let path = self.root().join("steam-proxy.ini");
                if fs::read(&path).unwrap_or_default() != data.as_bytes() {
                    atomic_write(&path, data.as_bytes())?;
                }
            }
        } else {
            let _ = fs::remove_file(self.root().join("steam-proxy.ini"));
        }
        if self.child.is_some() && !self.preparing && !ready && now() - self.session > 45. {
            self.stop();
            self.status = "代理状态超时，已停止 / Proxy health timed out; stopped".into();
        }
        let stamp = fs::metadata(self.root().join("catalog.json"))
            .and_then(|m| m.modified())
            .ok();
        let planet_stamp = fs::metadata(self.root().join("planets.json"))
            .and_then(|m| m.modified())
            .ok();
        if stamp != self.catalog_stamp || planet_stamp != self.planet_stamp {
            self.catalog = catalog(&self.profile)?;
            self.catalog_stamp = stamp;
            self.planet_stamp = planet_stamp;
        }
        let catalog_updated = stamp
            .and_then(|s| s.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_millis());
        let planets_updated = planet_stamp
            .and_then(|s| s.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_millis());
        Ok(
            json!({"active":self.child.is_some()&&!self.preparing,"preparing":self.preparing,"ready":ready,"trusted":trusted,"certificateExists":self.cert().exists(),"health":health,"status":self.status,"catalogUpdated":catalog_updated,"planetsUpdated":planets_updated}),
        )
    }
    fn bridge(&self) -> Result<String> {
        let src = std::env::current_exe()?.with_file_name("cpv-steam-bridge.exe");
        let dst = self.root().join("steam-bridge.exe");
        let bytes = fs::read(src)?;
        if fs::read(&dst).unwrap_or_default() != bytes {
            atomic_write(&dst, &bytes)?;
        }
        Ok(format!("\"{}\" %command%", dst.display()))
    }
    fn request(&mut self, method: &str, args: Value) -> Result<Value> {
        match method {
            "bootstrap" => Ok(
                json!({"settings":self.settings,"targets":self.targets,"catalog":self.catalog,"state":self.poll()?,"version":diagnostics::VERSION,"diagnostics_directory":diagnostics::directory(&self.profile)}),
            ),
            "state" => self.poll(),
            "catalog" => {
                self.poll()?;
                Ok(self.catalog.clone())
            }
            "save_target" => {
                let target = &args["target"];
                let mut rows = self.targets.as_array().unwrap().clone();
                if let Some(i) = rows.iter().position(|t| t["planet"] == target["planet"]) {
                    rows[i] = target.clone();
                } else {
                    rows.push(target.clone());
                }
                self.persist(json!(rows))
            }
            "remove_target" => {
                let rows: Vec<_> = self
                    .targets
                    .as_array()
                    .unwrap()
                    .iter()
                    .filter(|t| t["planet"] != args["planet"])
                    .cloned()
                    .collect();
                self.persist(json!(rows))
            }
            "import" => {
                let path = args["path"]
                    .as_str()
                    .ok_or_else(|| anyhow::anyhow!("Missing path"))?;
                self.persist(import_document(read_json(Path::new(path))?)?)
            }
            "export" => {
                let path = args["path"]
                    .as_str()
                    .ok_or_else(|| anyhow::anyhow!("Missing path"))?;
                write_json(Path::new(path), &json!({"schema":2,"targets":self.targets}))?;
                Ok(json!(true))
            }
            "restore_backup" => {
                let v = read_json(&self.profile.join("war-targets.backup.json"))?;
                self.persist(import_document(v)?)
            }
            "settings" => {
                ensure!(args.is_object(), "Invalid settings");
                let mut next = self.settings.clone();
                for (key, value) in args.as_object().unwrap() {
                    match key.as_str() {
                        "language" => ensure!(value == "zh" || value == "en", "Invalid language"),
                        "theme" => ensure!(
                            value == "light" || value == "dark" || value == "system",
                            "Invalid theme"
                        ),
                        "material" => ensure!(
                            value == "frosted" || value == "liquid" || value == "solid",
                            "Invalid material"
                        ),
                        "opacity" => ensure!(
                            value.as_f64().is_some_and(|n| n >= 0.2 && n <= 1.),
                            "Invalid opacity"
                        ),
                        "accent" => {
                            integer(value, 0, 3)?;
                        }
                        "useSystemProxy" => {
                            ensure!(value.is_boolean(), "Invalid proxy switch");
                            ensure!(
                                self.child.is_none() || self.settings["useSystemProxy"] == *value,
                                "停止代理后再修改连接路线 / Stop proxy before changing route"
                            );
                        }
                        "runtime" => ensure!(value.is_string(), "Invalid runtime"),
                        "diagnostics" => ensure!(value.is_boolean(), "Invalid diagnostics switch"),
                        _ => bail!("Unknown setting: {key}"),
                    };
                    next[key] = value.clone();
                }
                write_json(&self.profile.join("cpv-settings.json"), &next)?;
                self.settings = next;
                Ok(self.settings.clone())
            }
            "start" => self.start(false),
            "diagnose" => {
                let state = self.poll()?;
                diagnostics::diagnose(&self.profile, &state)
            }
            "export_diagnostics" => {
                let path = args["path"]
                    .as_str()
                    .context("Missing diagnostic export path")?;
                let state = self.poll()?;
                let report = diagnostics::diagnose(&self.profile, &state)?;
                diagnostics::export(&self.profile, Path::new(path), report, &args["client"])?;
                Ok(json!(true))
            }
            "prepare_certificate" => self.start(true),
            "stop" => {
                self.stop();
                self.poll()
            }
            "install_certificate" => {
                ensure!(
                    self.cert().is_file(),
                    "请先生成证书 / Generate certificate first"
                );
                let thumb = platform::thumbprint(&self.cert())?;
                platform::install_certificate_elevated(&self.cert())?;
                self.settings["installedCa"] = json!(thumb);
                write_json(&self.profile.join("cpv-settings.json"), &self.settings)?;
                self.poll()
            }
            "remove_certificate" => {
                let thumb = self.settings["installedCa"]
                    .as_str()
                    .ok_or_else(|| anyhow::anyhow!("没有本程序安装记录 / No owned certificate"))?
                    .to_string();
                ensure!(
                    thumb.len() == 40 && thumb.chars().all(|c| c.is_ascii_hexdigit()),
                    "Invalid thumbprint"
                );
                platform::remove_certificate(&thumb)?;
                self.settings.as_object_mut().unwrap().remove("installedCa");
                write_json(&self.profile.join("cpv-settings.json"), &self.settings)?;
                self.poll()
            }
            "steam_options" => Ok(json!(self.bridge()?)),
            "launch_game" => {
                let state = self.poll()?;
                ensure!(
                    state["ready"] == true && state["trusted"] == true,
                    "请先开启代理并信任证书 / Start proxy and trust certificate first"
                );
                ensure!(
                    self.root().join("steam-bridge.exe").exists(),
                    "请先配置 Steam 启动选项 / Configure Steam launch options first"
                );
                platform::open_steam()?;
                Ok(json!(true))
            }
            "shutdown" => {
                self.stop();
                Ok(json!(true))
            }
            _ => bail!("Unknown method: {method}"),
        }
    }
}
impl Drop for Host {
    fn drop(&mut self) {
        if self.child.is_some() {
            self.stop();
        }
    }
}
fn default_profile() -> Result<PathBuf> {
    if let Some(path) = std::env::var_os("CPV_PROFILE") {
        return Ok(PathBuf::from(path));
    }
    let mut candidates = Vec::new();
    if let Some(path) = std::env::var_os("LOCALAPPDATA") {
        candidates.push(PathBuf::from(path).join("CPV/RustProfile"));
    }
    if let Ok(path) = std::env::current_exe() {
        if let Some(dir) = path.parent() {
            candidates.push(dir.join(".CPV/Profile"));
        }
    }
    if let Some(path) = std::env::var_os("APPDATA") {
        candidates.push(PathBuf::from(path).join("CPV/RustProfile"));
    }
    for path in candidates {
        if fs::create_dir_all(&path).is_err() {
            continue;
        }
        let probe = path.join(format!(".cpv-write-check-{}", std::process::id()));
        if let Ok(file) = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&probe)
        {
            drop(file);
            let _ = fs::remove_file(probe);
            return Ok(path);
        }
    }
    bail!(
        "没有可写的配置目录，请设置 CPV_PROFILE / No writable configuration directory; set CPV_PROFILE"
    )
}
fn main() {
    #[cfg(windows)]
    {
        let args: Vec<_> = std::env::args_os().skip(1).collect();
        if args
            .first()
            .is_some_and(|arg| arg == "--install-certificate")
        {
            let code = if args.len() == 4 {
                platform::elevated_certificate_helper(
                    Path::new(&args[1]),
                    &args[2].to_string_lossy(),
                    &args[3].to_string_lossy(),
                )
            } else {
                87
            };
            std::process::exit(code as i32);
        }
    }

    let profile = match default_profile() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("CPV startup: {e:#}");
            return;
        }
    };
    let diagnostic_dir = diagnostics::directory(&profile);
    diagnostics::record(
        &diagnostic_dir,
        "core.jsonl",
        "startup",
        json!({"version":diagnostics::VERSION,"os":std::env::consts::OS,"architecture":std::env::consts::ARCH}),
    );
    let mut host = match Host::new(profile) {
        Ok(h) => h,
        Err(e) => {
            diagnostics::record(
                &diagnostic_dir,
                "core.jsonl",
                "startup_error",
                json!({"error":diagnostics::safe(&format!("{e:#}"))}),
            );
            eprintln!("CPV startup: {e:#}");
            return;
        }
    };
    let input = io::stdin();
    let mut output = io::BufWriter::new(io::stdout().lock());
    for line in input.lock().lines() {
        let Ok(line) = line else { break };
        if line.len() > 8 * 1024 * 1024 {
            break;
        }
        let request: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let method = request["method"].as_str().unwrap_or("");
        let started = std::time::Instant::now();
        let response = match host.request(method, request["args"].clone()) {
            Ok(v) => json!({"id":request["id"],"result":v}),
            Err(e) => json!({"id":request["id"],"error":format!("{e:#}")}),
        };
        if response.get("error").is_some()
            || (host.settings["diagnostics"] == true && !["state", "catalog"].contains(&method))
        {
            diagnostics::record(
                &diagnostic_dir,
                "core.jsonl",
                "request",
                json!({"method":method,"ok":response.get("error").is_none(),"elapsed_ms":started.elapsed().as_millis(),"error":response.get("error").and_then(Value::as_str).map(diagnostics::safe)}),
            );
        }
        if serde_json::to_writer(&mut output, &response).is_err()
            || writeln!(output).is_err()
            || output.flush().is_err()
        {
            break;
        }
        if method == "shutdown" {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn profile(label: &str) -> PathBuf {
        let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../build/rust-tests")
            .join(format!(
                "{label}-{}-{}",
                std::process::id(),
                (now() * 1000000.) as u64
            ));
        fs::create_dir_all(&p).unwrap();
        p.canonicalize().unwrap()
    }
    #[test]
    fn saved_state_survives_restart_without_starting_proxy() {
        let p = profile("persist");
        {
            let mut h = Host::new(p.clone()).unwrap();
            assert_eq!(h.poll().unwrap()["active"], false);
            h.persist(json!([{"planet":64,"effects":[1346,1431]}]))
                .unwrap();
            h.request(
                "settings",
                json!({"language":"en","theme":"dark","material":"liquid"}),
            )
            .unwrap();
            assert!(h.request("settings", json!({"opacity":2})).is_err());
        }
        let mut h = Host::new(p.clone()).unwrap();
        assert_eq!(h.targets[0]["effects"], json!([1346, 1431]));
        assert_eq!(h.settings["language"], "en");
        assert_eq!(h.poll().unwrap()["active"], false);
        assert!(!p.join("war-proxy/steam-proxy.ini").exists());
        assert!(!h.cert().exists());
    }
    #[test]
    fn invalid_plan_preserves_saved_document() {
        let p = profile("invalid");
        let mut h = Host::new(p.clone()).unwrap();
        h.persist(json!([{"planet":1,"effects":[]}])).unwrap();
        let before = fs::read(p.join("war-targets.json")).unwrap();
        assert!(h.persist(json!([{"planet":-1,"effects":[]}])).is_err());
        assert_eq!(fs::read(p.join("war-targets.json")).unwrap(), before);
    }
    #[cfg(windows)]
    #[test]
    fn profile_exclusive_lock() {
        let p = profile("lock");
        let h = Host::new(p.clone()).unwrap();
        assert!(Host::new(p.clone()).is_err());
        drop(h);
        assert!(Host::new(p).is_ok());
    }
    #[test]
    fn corrupt_preferences_are_not_overwritten() {
        let p = profile("bad-settings");
        write_json(&p.join("cpv-settings.json"), &json!({"accent":99})).unwrap();
        assert!(Host::new(p.clone()).is_err());
        assert_eq!(
            read_json(&p.join("cpv-settings.json")).unwrap()["accent"],
            99
        );
    }
}
