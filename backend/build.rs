use sha2::{Digest, Sha256};
use std::{env, fs, path::PathBuf, process::Command};
fn main() {
    let addon = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap())
        .join("../proxy/war_status_addon.py");
    let digest = format!(
        "{:x}",
        Sha256::digest(fs::read(&addon).expect("Missing proxy source"))
    );
    println!("cargo:rerun-if-changed={}", addon.display());
    println!("cargo:rustc-env=CPV_ADDON_SHA256={digest}");
    println!("cargo:rerun-if-env-changed=CPV_PAYLOAD");
    println!("cargo:rerun-if-changed=../assets/app.ico");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    if let Some(payload) = env::var_os("CPV_PAYLOAD") {
        println!(
            "cargo:rerun-if-changed={}",
            PathBuf::from(payload).display()
        );
    }
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let icon = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap())
        .join("../assets/app.ico")
        .canonicalize()
        .unwrap();
    let manifest = out.join("launcher.manifest");
    fs::write(&manifest,r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0"><trustInfo xmlns="urn:schemas-microsoft-com:asm.v3"><security><requestedPrivileges><requestedExecutionLevel level="asInvoker" uiAccess="false"/></requestedPrivileges></security></trustInfo><application xmlns="urn:schemas-microsoft-com:asm.v3"><windowsSettings><longPathAware xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">true</longPathAware><dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true</dpiAware></windowsSettings></application></assembly>"#).unwrap();
    let rc = out.join("launcher.rc");
    let res = out.join("launcher.res");
    let escaped = |p: PathBuf| p.to_string_lossy().replace('\\', "\\\\");
    fs::write(&rc,format!("#pragma code_page(65001)\n1 ICON \"{}\"\n1 24 \"{}\"\n1 VERSIONINFO FILEVERSION 2,0,0,4 PRODUCTVERSION 2,0,0,4 FILEOS 0x40004 FILETYPE 1 BEGIN BLOCK \"StringFileInfo\" BEGIN BLOCK \"040904b0\" BEGIN VALUE \"FileDescription\", \"自定义星球和变种\\0\" VALUE \"ProductName\", \"自定义星球和变种\\0\" VALUE \"ProductVersion\", \"2.0.0-preview.4\\0\" VALUE \"LegalCopyright\", \"CPV contributors; AGPL-3.0-only\\0\" END END BLOCK \"VarFileInfo\" BEGIN VALUE \"Translation\", 0x409, 1200 END END\n",escaped(icon),escaped(manifest))).unwrap();
    let status = Command::new(env::var_os("RC").unwrap_or_else(|| "rc.exe".into()))
        .arg("/nologo")
        .arg(format!("/fo{}", res.display()))
        .arg(rc)
        .status()
        .unwrap();
    assert!(status.success(), "Windows resource build failed");
    println!("cargo:rustc-link-arg-bin=cpv-core={}", res.display());
    println!(
        "cargo:rustc-link-arg-bin=cpv-steam-bridge={}",
        res.display()
    );
    if env::var_os("CARGO_FEATURE_BUNDLE").is_some() {
        println!("cargo:rustc-link-arg-bin=cpv-launcher={}", res.display());
    }
}
