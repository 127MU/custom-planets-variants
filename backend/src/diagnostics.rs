use anyhow::{Result, ensure};
use cpv_core::{atomic_write, read_json, verified_addon, write_json};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};
static WRITE_LOCK: Mutex<()> = Mutex::new(());
pub const VERSION: &str = "2.0.0";
pub fn stamp() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}
pub fn directory(profile: &Path) -> PathBuf {
    std::env::var_os("CPV_DIAGNOSTIC_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| profile.join("diagnostics"))
}
pub fn safe(text: &str) -> String {
    let lower = text.to_ascii_lowercase();
    if [
        "authorization",
        "access_token",
        "refresh_token",
        "password",
        "private key",
        "private_key",
        "cookie",
    ]
    .iter()
    .any(|word| lower.contains(word))
    {
        return "[敏感字段已隐藏 / sensitive field redacted]".into();
    }
    let mut text = text.chars().take(2000).collect::<String>();
    if let Some(home) = std::env::var_os("USERPROFILE") {
        let home = home.to_string_lossy();
        text = text
            .replace(home.as_ref(), "%USERPROFILE%")
            .replace(&home.replace('\\', "/"), "%USERPROFILE%");
    }
    text
}
pub fn record(dir: &Path, file: &str, event: &str, data: Value) {
    let Ok(_guard) = WRITE_LOCK.lock() else {
        return;
    };
    let result = (|| -> Result<()> {
        fs::create_dir_all(dir)?;
        let path = dir.join(file);
        if fs::metadata(&path).is_ok_and(|m| m.len() > 1024 * 1024) {
            let old = dir.join(format!("{file}.1"));
            let _ = fs::copy(&path, old);
            atomic_write(&path, b"")?;
        }
        let line = json!({"time_epoch_ms":stamp(),"event":event,"data":data});
        let mut output = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)?;
        serde_json::to_writer(&mut output, &line)?;
        writeln!(output)?;
        Ok(())
    })();
    let _ = result;
}
pub fn logs(dir: &Path) -> Vec<Value> {
    let mut output = Vec::new();
    for file in [
        "core.jsonl",
        "core.jsonl.1",
        "ui.jsonl",
        "ui.jsonl.1",
        "launcher.jsonl",
        "launcher.jsonl.1",
    ] {
        let Ok(mut input) = fs::File::open(dir.join(file)) else {
            continue;
        };
        let Ok(meta) = input.metadata() else { continue };
        let begin = meta.len().saturating_sub(200 * 1024);
        if input.seek(SeekFrom::Start(begin)).is_err() {
            continue;
        }
        let mut bytes = Vec::new();
        if input.take(200 * 1024).read_to_end(&mut bytes).is_err() {
            continue;
        }
        let text = String::from_utf8_lossy(&bytes);
        for line in text.lines().rev().take(700) {
            if let Ok(value) = serde_json::from_str::<Value>(line) {
                output.push(json!({"source":file,"entry":scrub(value)}));
            }
        }
    }
    output
}
fn scrub(value: Value) -> Value {
    match value {
        Value::String(s) => json!(safe(&s)),
        Value::Array(rows) => json!(rows.into_iter().map(scrub).collect::<Vec<_>>()),
        Value::Object(rows) => Value::Object(
            rows.into_iter()
                .map(|(key, value)| {
                    let lower = key.to_ascii_lowercase();
                    let value = if [
                        "authorization",
                        "cookie",
                        "access_token",
                        "refresh_token",
                        "password",
                        "private_key",
                    ]
                    .contains(&lower.as_str())
                    {
                        json!("[redacted]")
                    } else {
                        scrub(value)
                    };
                    (key, value)
                })
                .collect(),
        ),
        other => other,
    }
}
pub fn diagnose(profile: &Path, state: &Value) -> Result<Value> {
    let root = std::env::current_exe()?.parent().unwrap().to_path_buf();
    let mut checks = Vec::new();
    let mut add = |key: &str, status: &str, detail: String| {
        checks.push(json!({"key":key,"status":status,"detail":safe(&detail)}))
    };
    let probe = profile.join(format!(".diagnostic-write-{}", std::process::id()));
    match atomic_write(&probe, b"CPV diagnostic write check") {
        Ok(()) => {
            let _ = fs::remove_file(probe);
            add("profile", "ok", "配置目录可写 / Profile is writable".into());
        }
        Err(e) => add(
            "profile",
            "error",
            format!("配置目录不可写 / Profile write failed: {e}"),
        ),
    }
    match read_json(&root.join("manifest.json")) {
        Ok(manifest) => {
            let important = [
                "自定义星球和变种.exe",
                "cpv-core.exe",
                "cpv-steam-bridge.exe",
                "flutter_windows.dll",
                "proxy/war_status_addon.py",
                "mitmproxy/python.exe",
                "mitmproxy/proxy_main.py",
                "mitmproxy/python312.dll",
            ];
            let mut failures = Vec::new();
            for name in important {
                let expected = manifest["files"][name].as_str();
                match fs::read(root.join(name)) {
                    Ok(bytes)
                        if expected.is_some_and(|expected| {
                            format!("{:x}", Sha256::digest(&bytes)) == expected
                        }) => {}
                    _ => failures.push(name),
                }
            }
            add(
                "files",
                if failures.is_empty() { "ok" } else { "error" },
                if failures.is_empty() {
                    "关键程序文件哈希一致 / Critical application files verified".into()
                } else {
                    format!("缺失或已改变 / Missing or changed: {}", failures.join(", "))
                },
            );
        }
        Err(e) => add(
            "files",
            "warning",
            format!("未找到可读打包清单 / Package manifest unavailable: {e}"),
        ),
    }
    match verified_addon(&root.join("proxy/war_status_addon.py")) {
        Ok(_) => add(
            "addon",
            "ok",
            "代理插件与核心版本一致 / Proxy plugin matches the core".into(),
        ),
        Err(e) => add(
            "addon",
            "error",
            format!("代理插件校验失败 / Proxy plugin verification failed: {e}"),
        ),
    }
    add(
        "certificate",
        if state["trusted"] == true {
            "ok"
        } else {
            "info"
        },
        if state["trusted"] == true {
            "当前用户已信任本机证书 / Local certificate trusted"
        } else {
            "证书尚未初始化或未信任 / Certificate not initialized or not trusted"
        }
        .into(),
    );
    add(
        "proxy",
        if state["ready"] == true {
            "ok"
        } else if state["active"] == true {
            "warning"
        } else {
            "info"
        },
        if state["ready"] == true {
            "代理状态有效 / Proxy health is current"
        } else if state["active"] == true {
            "代理启动但尚未就绪 / Proxy started but not ready"
        } else {
            "代理未开启，本次未自动启动 / Proxy off; diagnostics did not start it"
        }
        .into(),
    );
    let env_flags: Vec<_> = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"]
        .into_iter()
        .filter(|key| std::env::var_os(key).is_some())
        .collect();
    let report = json!({"schema":1,"product":"自定义星球和变种 / Custom Planets & Variants","version":VERSION,"created_at_epoch_ms":stamp(),"os":std::env::consts::OS,"architecture":std::env::consts::ARCH,"proxy_environment_variables_present":env_flags,"checks":checks,"state":{"active":state["active"],"ready":state["ready"],"certificate_trusted":state["trusted"],"failures":state["health"]["failures"],"connection":state["health"]["connection"],"statuses":state["health"]["statuses"],"rewrites":state["health"]["rewrites"]},"privacy":"No account identifiers, authentication headers, HTTP bodies, CA private keys or screenshots collected."});
    record(
        &directory(profile),
        "core.jsonl",
        "diagnostic_report",
        json!({"checks":report["checks"]}),
    );
    Ok(report)
}
pub fn export(profile: &Path, path: &Path, report: Value, client: &Value) -> Result<()> {
    ensure!(
        client.is_object() || client.is_null(),
        "Invalid client diagnostic data"
    );
    let mut output = scrub(report);
    output["events"] = json!(logs(&directory(profile)));
    let mut safe_client = json!({});
    for key in [
        "operating_system",
        "language",
        "theme",
        "material",
        "last_error",
    ] {
        if let Some(value) = client.get(key).and_then(Value::as_str) {
            safe_client[key] = json!(safe(value));
        }
    }
    output["client"] = safe_client;
    write_json(path, &output)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn secrets_are_redacted() {
        let v = scrub(
            json!({"authorization":"Bearer secret","nested":["access_token=secret","ordinary error"],"password":"hidden"}),
        );
        let s = v.to_string();
        assert!(!s.contains("Bearer secret"));
        assert!(!s.contains("=secret"));
        assert!(!s.contains("hidden"));
        assert!(s.contains("ordinary error"));
    }
    #[test]
    fn private_files_are_never_exported() {
        let dir = std::env::temp_dir().join(format!("cpv-diag-{}-{}", std::process::id(), stamp()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("mitmproxy-ca.pem"), "PRIVATE CONTENT").unwrap();
        record(&dir, "core.jsonl", "check", json!({"message":"ok"}));
        let events = logs(&dir);
        assert_eq!(events.len(), 1);
        assert!(
            !serde_json::to_string(&events)
                .unwrap()
                .contains("PRIVATE CONTENT")
        );
        fs::remove_file(dir.join("mitmproxy-ca.pem")).unwrap();
        fs::remove_file(dir.join("core.jsonl")).unwrap();
        fs::remove_dir(dir).unwrap();
    }
}
