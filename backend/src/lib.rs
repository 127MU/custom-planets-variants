use anyhow::{Result, bail, ensure};
use serde_json::{Value, json};
use std::{collections::BTreeSet, fs, io::Write, path::Path};

pub const CATALOG: &str = include_str!("../../assets/war_catalog.json");
pub const ADDON_SHA256: &str = env!("CPV_ADDON_SHA256");

pub fn verified_addon(path: &Path) -> Result<Vec<u8>> {
    use sha2::{Digest, Sha256};
    ensure!(
        fs::metadata(path)?.len() <= 512 * 1024,
        "代理脚本过大 / Proxy script too large"
    );
    let bytes = fs::read(path)?;
    ensure!(
        format!("{:x}", Sha256::digest(&bytes)) == ADDON_SHA256,
        "代理资源与核心版本不匹配或已被改动 / Proxy resource does not match this core"
    );
    Ok(bytes)
}

pub fn integer(v: &Value, low: i64, high: i64) -> Result<i64> {
    let n = v
        .as_i64()
        .ok_or_else(|| anyhow::anyhow!("需要整数 / Integer required"))?;
    ensure!(
        (low..=high).contains(&n),
        "数值超出范围 / Value out of range"
    );
    Ok(n)
}

pub fn validate_targets(input: &Value) -> Result<Value> {
    let rows = input
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("方案必须是列表 / Expected a plan list"))?;
    ensure!(rows.len() <= 64, "最多 64 颗星球 / Maximum 64 planets");
    let mut planets = BTreeSet::new();
    let mut output = Vec::new();
    for row in rows {
        ensure!(row.is_object(), "星球方案必须是对象 / Invalid planet plan");
        let planet = integer(&row["planet"], 0, 10000)?;
        ensure!(
            planets.insert(planet),
            "同一星球不能重复 / Duplicate planet"
        );
        let ids = row["effects"]
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("缺少效果列表 / Missing effects"))?;
        ensure!(
            ids.len() <= 32,
            "每颗星球最多 32 个效果 / Maximum 32 effects per planet"
        );
        let mut effects = Vec::new();
        for id in ids {
            let id = integer(id, 1, i32::MAX as i64)?;
            if !effects.contains(&id) {
                effects.push(id);
            }
        }
        let mut t = json!({"planet": planet, "effects": effects});
        for (key, default) in [
            ("enabled", true),
            ("campaign", false),
            ("open_regions", false),
            ("initialize_regions", false),
        ] {
            let value = row.get(key).cloned().unwrap_or(json!(default));
            ensure!(
                value.is_boolean(),
                "开关必须为布尔值 / Invalid switch: {key}"
            );
            t[key] = value;
        }
        for (key, default, low, high) in [
            ("owner", 0, 0, 4),
            ("campaign_type", 0, 0, 4),
            ("campaign_race", 0, 0, 4),
            ("defense_source", -1, -1, 10000),
            ("defense_level", 20, 1, 1000),
            ("defense_hours", 48, 1, 168),
            ("defense_count", 38, 1, 1000),
        ] {
            let value = row.get(key).cloned().unwrap_or(json!(default));
            integer(&value, low, high)?;
            t[key] = value;
        }
        ensure!(
            !t["initialize_regions"].as_bool().unwrap()
                || (t["campaign"] == true && t["campaign_race"].as_i64().unwrap() >= 2),
            "初始化分区需开启战役并选择敌人 / Select a campaign and enemy before initializing regions"
        );
        if t["campaign_type"] == 4 {
            ensure!(
                t["campaign"] == true
                    && t["owner"] == 1
                    && t["campaign_race"].as_i64().unwrap() >= 2,
                "防守需开启战役、超级地球归属与敌人 / Invalid defense campaign"
            );
            ensure!(
                t["defense_source"].as_i64().unwrap() >= 0 && t["defense_source"] != planet,
                "请选择另一颗进攻来源星球 / Select another source planet"
            );
        }
        output.push(t);
    }
    Ok(json!(output))
}

pub fn read_json(path: &Path) -> Result<Value> {
    ensure!(
        fs::metadata(path)?.len() <= 8 * 1024 * 1024,
        "配置文件过大 / Configuration too large"
    );
    Ok(serde_json::from_slice(&fs::read(path)?)?)
}

/// Write a complete sibling file, then atomically replace the destination.
/// No delete-before-rename window; a failed write preserves the old document.
pub fn atomic_write(path: &Path, data: &[u8]) -> Result<()> {
    fs::create_dir_all(
        path.parent()
            .ok_or_else(|| anyhow::anyhow!("Invalid path"))?,
    )?;
    let temp = path.with_extension(format!("cpv-{}.tmp", std::process::id()));
    let result = (|| -> Result<()> {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)?;
        file.write_all(data)?;
        file.sync_all()?;
        drop(file);
        #[cfg(windows)]
        {
            use std::os::windows::ffi::OsStrExt;
            unsafe extern "system" {
                fn MoveFileExW(from: *const u16, to: *const u16, flags: u32) -> i32;
            }
            let from: Vec<u16> = temp.as_os_str().encode_wide().chain(Some(0)).collect();
            let to: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
            if unsafe { MoveFileExW(from.as_ptr(), to.as_ptr(), 1 | 8) } == 0 {
                return Err(std::io::Error::last_os_error().into());
            }
        }
        #[cfg(not(windows))]
        fs::rename(&temp, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}
pub fn write_json(path: &Path, data: &Value) -> Result<()> {
    atomic_write(path, &serde_json::to_vec_pretty(data)?)
}

pub fn import_document(value: Value) -> Result<Value> {
    if let Some(schema) = value.get("schema") {
        ensure!(schema == 2, "不支持的方案版本 / Unsupported schema");
    }
    let mut targets = value["targets"].clone();
    let rows = targets
        .as_array_mut()
        .ok_or_else(|| anyhow::anyhow!("缺少方案列表 / Missing targets"))?;
    for t in rows {
        if t.get("effects").is_none() {
            t["effects"] = value["variants"][t["variant"].as_str().unwrap_or("")].clone();
        }
    }
    validate_targets(&targets)
}

pub fn catalog(profile: &Path) -> Result<Value> {
    let mut meta: Value = serde_json::from_str(CATALOG)?;
    if let Ok(live) = read_json(&profile.join("war-proxy/catalog.json")) {
        if let Some(rows) = live["effects"].as_array().filter(|rows| !rows.is_empty()) {
            let mut merged = Vec::new();
            let mut seen = BTreeSet::new();
            for row in rows {
                let Some(id) = row["id"].as_i64().filter(|id| *id > 0) else {
                    continue;
                };
                if !seen.insert(id) {
                    bail!("在线目录含重复 ID / Duplicate live effect ID");
                }
                let reference = &meta["effect_reference"][id.to_string()];
                let cached = meta["effects"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|e| e["id"] == id);
                let matched = cached.filter(|e| {
                    e["effectType"] == row["effectType"]
                        && (reference.get("nameHash").is_none()
                            || reference["nameHash"] == row["nameHash"])
                });
                let mut e = matched.cloned().unwrap_or(json!({"id":id,"name":format!("未确认效果 #{id}"),"englishName":format!("Unresolved effect #{id}"),"experimental":true,"groupKey":"unknown","groupLabel":"未解效果"}));
                for (key, value) in row
                    .as_object()
                    .ok_or_else(|| anyhow::anyhow!("Invalid live row"))?
                {
                    e[key] = value.clone();
                }
                // Do not reuse a stale translation when an ID changes meaning.
                if matched.is_none() {
                    e["experimental"] = json!(true);
                    let (key, label) = match row["effectType"].as_i64() {
                        Some(71) => ("enemies", "敌情与变种"),
                        Some(40) => ("tags", "配套星图词条"),
                        Some(32) => ("stratagems", "临时配发战备"),
                        Some(36) => ("equipment", "临时装备"),
                        Some(94) => ("variants", "实验性战备变体"),
                        Some(87 | 88 | 89) => ("tactical", "空间站与战术行动"),
                        Some(25 | 56 | 61 | 63) => ("supplies", "弹药与补给"),
                        Some(54 | 55) => ("intel", "情报与侦察"),
                        Some(1 | 21 | 47 | 48 | 49 | 51) => ("combat", "作战增减益"),
                        _ => ("unknown", "未解效果"),
                    };
                    e["groupKey"] = json!(key);
                    e["groupLabel"] = json!(label);
                    if let Some(hash) = row["nameHash"].as_i64() {
                        if let Some(name) = meta["strings"][(hash as u32).to_string()].as_str() {
                            e["name"] = json!(name);
                            e["translation_source"] = json!("游戏文本");
                        }
                    }
                }
                if let Some(hash) = row["descriptionGamePlayShortHash"].as_i64() {
                    if let Some(description) = meta["strings"][(hash as u32).to_string()].as_str() {
                        e["description"] = json!(description);
                    }
                }
                e["cached"] = json!(false);
                merged.push(e);
            }
            if !merged.is_empty() {
                meta["effects"] = json!(merged);
            }
        }
    }
    if let Ok(live) = read_json(&profile.join("war-proxy/planets.json")) {
        if let Some(rows) = live["planets"].as_array() {
            for row in rows {
                let Some(id) = row["index"].as_i64().filter(|n| (0..=10000).contains(n)) else {
                    continue;
                };
                let planets = meta["planets"].as_array_mut().unwrap();
                if let Some(p) = planets.iter_mut().find(|p| p["id"] == id) {
                    p["owner"] = row["owner"].clone();
                    p["players"] = row["players"].clone();
                } else {
                    planets.push(json!({"id":id,"name":format!("星球 #{id}"),"englishName":format!("Planet #{id}"),"owner":row["owner"],"players":row["players"]}));
                }
            }
        }
    }
    // Large game string dictionary stays inside the core; UI only receives display records.
    Ok(
        json!({"effects":meta["effects"],"planets":meta["planets"],"revision":meta["catalog_revision"]}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn proxy_resource_is_verified_before_loading() {
        let original = Path::new(env!("CARGO_MANIFEST_DIR")).join("../proxy/war_status_addon.py");
        let mut bytes = verified_addon(&original).unwrap();
        bytes.extend_from_slice(b"\n# changed\n");
        let path = std::env::temp_dir().join(format!("cpv-addon-check-{}.py", std::process::id()));
        fs::write(&path, bytes).unwrap();
        assert!(verified_addon(&path).is_err());
        fs::remove_file(path).unwrap();
    }
    #[test]
    fn normalize_and_reject() {
        let t = validate_targets(&json!([{"planet":1,"effects":[1346,1346,1431]}])).unwrap();
        assert_eq!(t[0]["effects"], json!([1346, 1431]));
        assert_eq!(t[0]["defense_hours"], 48);
        for bad in [
            json!([{"planet":1.5,"effects":[]}]),
            json!([{"planet":1,"effects":[true]}]),
            json!([{"planet":1,"effects":[],"enabled":1}]),
            json!([{"planet":1,"effects":[],"initialize_regions":true}]),
            json!([{"planet":1,"effects":[]},{"planet":1,"effects":[]}]),
        ] {
            assert!(validate_targets(&bad).is_err());
        }
    }
    #[test]
    fn defense_constraints() {
        assert!(validate_targets(&json!([{"planet":1,"effects":[],"campaign_type":4}])).is_err());
        assert!(validate_targets(&json!([{"planet":1,"effects":[],"campaign":true,"owner":1,"campaign_race":3,"campaign_type":4,"defense_source":2}])).is_ok());
    }
    #[test]
    fn legacy_import() {
        assert!(
            import_document(
                json!({"targets":[{"planet":3,"variant":"a"}],"variants":{"a":[1346]}})
            )
            .is_ok()
        );
    }
    #[test]
    fn complete_catalog() {
        let v: Value = serde_json::from_str(CATALOG).unwrap();
        assert_eq!(v["effects"].as_array().unwrap().len(), 315);
        assert!(v["planets"].as_array().unwrap().len() >= 273);
        for row in v["effects"].as_array().unwrap() {
            assert!(row["groupKey"].is_string());
            assert!(row["englishName"].is_string());
        }
    }
    #[test]
    fn live_catalog_drops_stale_ids_and_does_not_reuse_changed_names() {
        let root = std::env::temp_dir().join(format!("cpv-live-catalog-{}", std::process::id()));
        fs::create_dir_all(root.join("war-proxy")).unwrap();
        let path = root.join("war-proxy/catalog.json");
        write_json(
            &path,
            &json!({"effects":[{"id":1431,"effectType":94,"nameHash":0}]}),
        )
        .unwrap();
        let live = catalog(&root).unwrap();
        assert_eq!(live["effects"].as_array().unwrap().len(), 1);
        assert_eq!(live["effects"][0]["groupKey"], "variants");
        assert_eq!(live["effects"][0]["experimental"], true);
        assert_ne!(live["effects"][0]["name"], "强酸变种（暂译）");
        write_json(&path, &json!({"effects":[{"id":1},{"id":1}]})).unwrap();
        assert!(catalog(&root).is_err());
        fs::remove_file(path).unwrap();
        fs::remove_dir(root.join("war-proxy")).unwrap();
        fs::remove_dir(root).unwrap();
    }
    #[test]
    fn atomic_replace_and_backup_data() {
        let root = std::env::temp_dir().join(format!("cpv-test-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let p = root.join("plan.json");
        write_json(&p, &json!({"n":1})).unwrap();
        write_json(&p, &json!({"n":2})).unwrap();
        assert_eq!(read_json(&p).unwrap()["n"], 2);
        fs::remove_file(p).unwrap();
        fs::remove_dir(root).unwrap();
    }
}
