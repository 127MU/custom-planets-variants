#![cfg_attr(windows, windows_subsystem = "windows")]
mod diagnostics;
use anyhow::{Context, Result, bail, ensure};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{Cursor, Read, Write},
    path::{Path, PathBuf},
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

const PAYLOAD: &[u8] = include_bytes!(env!("CPV_PAYLOAD"));
const PREFIX: &str = "CPV_2.0.0-preview.3";
fn hash(data: &[u8]) -> String {
    format!("{:x}", Sha256::digest(data))
}
fn writable(path: &Path) -> bool {
    if fs::create_dir_all(path).is_err() {
        return false;
    }
    let probe = path.join(format!(".cpv-probe-{}", std::process::id()));
    let Ok(file) = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&probe)
    else {
        return false;
    };
    drop(file);
    let _ = fs::remove_file(probe);
    true
}
fn cache() -> Result<PathBuf> {
    if let Some(path) = std::env::var_os("CPV_LAUNCHER_CACHE") {
        let path = PathBuf::from(path);
        ensure!(
            writable(&path),
            "无法写入指定缓存 / Cannot write to the selected cache"
        );
        return Ok(path.canonicalize()?);
    }
    let mut paths = Vec::new();
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        paths.push(PathBuf::from(local).join("CPV/RuntimeRust"));
    }
    if let Some(parent) = std::env::current_exe()?.parent() {
        paths.push(parent.join(".CPV/Runtime"));
    }
    paths.push(std::env::temp_dir().join("CPV/RuntimeRust"));
    for path in paths {
        if writable(&path) {
            return Ok(path.canonicalize()?);
        }
    }
    bail!("无法创建运行时缓存，请检查可用空间与目录写入权限 / No writable runtime cache")
}
fn verified(root: &Path) -> Result<usize> {
    // The trust anchor is the manifest inside this executable's immutable ZIP,
    // never a replacement manifest supplied by the writable cache.
    let mut archive = zip::ZipArchive::new(Cursor::new(PAYLOAD))?;
    let mut entry = archive.by_name(&format!("{PREFIX}/manifest.json"))?;
    ensure!(
        entry.size() <= 8 * 1024 * 1024,
        "Embedded manifest too large"
    );
    let mut expected = Vec::new();
    entry.read_to_end(&mut expected)?;
    ensure!(
        fs::read(root.join("manifest.json"))? == expected,
        "缓存清单被改动 / Cached manifest changed"
    );
    let manifest: serde_json::Value = serde_json::from_slice(&expected)?;
    let files = manifest["files"]
        .as_object()
        .context("Missing package manifest")?;
    ensure!(files.len() <= 4096, "Too many runtime files");
    for (name, expected) in files {
        let relative = Path::new(name);
        ensure!(
            !relative.is_absolute()
                && relative
                    .components()
                    .all(|c| matches!(c, std::path::Component::Normal(_))),
            "Unsafe manifest path"
        );
        let file = root.join(relative);
        let actual = file.canonicalize()?;
        ensure!(actual.starts_with(root), "Runtime file escapes cache");
        let mut reader = fs::File::open(&file)?;
        let mut digest = Sha256::new();
        let mut chunk = [0u8; 65536];
        loop {
            let n = reader.read(&mut chunk)?;
            if n == 0 {
                break;
            }
            digest.update(&chunk[..n]);
        }
        ensure!(
            format!("{:x}", digest.finalize()) == expected.as_str().unwrap_or(""),
            "运行时校验失败 / Runtime verification failed: {name}"
        );
    }
    ensure!(
        root.join("自定义星球和变种.exe").is_file() && root.join("cpv-core.exe").is_file(),
        "Application files missing"
    );
    Ok(files.len())
}
fn expand(cache: &Path, id: &str) -> Result<(PathBuf, usize)> {
    let target = cache.join(id);
    let lock_path = cache.join(format!("{id}.lock"));
    let lock = loop {
        let mut options = fs::OpenOptions::new();
        options.create(true).read(true).write(true);
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            options.share_mode(0);
        }
        match options.open(&lock_path) {
            Ok(file) => break file,
            Err(e) => {
                return Err(e).context("另一个实例正在准备运行时，请稍后重试 / Another instance is preparing the runtime");
            }
        }
    };
    if target.is_dir() {
        if let Ok(files) = verified(&target) {
            drop(lock);
            return Ok((target, files));
        }
    }
    let stage = cache.join(format!(
        "{id}.stage-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis()
    ));
    fs::create_dir(&stage)?;
    let mut zip = zip::ZipArchive::new(Cursor::new(PAYLOAD))?;
    ensure!(zip.len() <= 4096, "Too many embedded files");
    let count = zip.len();
    let mut progress = Progress::new()?;
    let mut total = 0u64;
    for i in 0..count {
        let mut entry = zip.by_index(i)?;
        let enclosed = entry.enclosed_name().context("Unsafe embedded path")?;
        let relative = enclosed
            .strip_prefix(PREFIX)
            .context("Unexpected payload root")?;
        if relative.as_os_str().is_empty() {
            continue;
        }
        ensure!(
            entry.unix_mode().is_none_or(|m| m & 0o170000 != 0o120000),
            "Embedded symlinks are not supported"
        );
        total = total
            .checked_add(entry.size())
            .context("Invalid payload size")?;
        ensure!(total <= 512 * 1024 * 1024, "Embedded runtime too large");
        let file = stage.join(relative);
        ensure!(file.starts_with(&stage), "Unsafe output path");
        if entry.is_dir() {
            fs::create_dir_all(file)?;
        } else {
            fs::create_dir_all(file.parent().context("Invalid output")?)?;
            let mut output = fs::OpenOptions::new()
                .create_new(true)
                .write(true)
                .open(file)?;
            std::io::copy(&mut entry, &mut output)?;
            output.flush()?;
        }
        progress.update(i + 1, count)?;
    }
    let files = verified(&stage)?;
    if target.exists() {
        // Only rename a verified in-cache directory; never recursively delete runtime files.
        ensure!(
            target.canonicalize()?.starts_with(cache),
            "Refusing to move a cache target outside the cache"
        );
        let old = cache.join(format!(
            "{id}.old-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis()
        ));
        ensure!(old.parent() == Some(cache), "Invalid backup target");
        fs::rename(&target, old)?;
    }
    fs::rename(&stage, &target)?;
    drop(progress);
    drop(lock);
    Ok((target, files))
}

#[cfg(windows)]
struct Progress {
    window: windows_sys::Win32::Foundation::HWND,
    label: windows_sys::Win32::Foundation::HWND,
    last: usize,
}
#[cfg(windows)]
impl Progress {
    fn new() -> Result<Self> {
        use windows_sys::Win32::{
            Graphics::Gdi::*, System::LibraryLoader::GetModuleHandleW, UI::WindowsAndMessaging::*,
        };
        if std::env::var_os("CPV_BUNDLE_VERIFY").is_some() {
            return Ok(Self {
                window: std::ptr::null_mut(),
                label: std::ptr::null_mut(),
                last: 0,
            });
        }
        unsafe {
            let module = GetModuleHandleW(std::ptr::null());
            let class = wide("CPVRuntimeProgress");
            let wc = WNDCLASSW {
                lpfnWndProc: Some(DefWindowProcW),
                hInstance: module,
                lpszClassName: class.as_ptr(),
                hCursor: LoadCursorW(std::ptr::null_mut(), IDC_WAIT),
                hbrBackground: (COLOR_WINDOW + 1) as _,
                ..std::mem::zeroed()
            };
            RegisterClassW(&wc);
            let title = wide("CPV · 正在启动 / Starting");
            let window = CreateWindowExW(
                WS_EX_APPWINDOW,
                class.as_ptr(),
                title.as_ptr(),
                WS_CAPTION | WS_SYSMENU | WS_VISIBLE,
                (GetSystemMetrics(SM_CXSCREEN) - 480) / 2,
                (GetSystemMetrics(SM_CYSCREEN) - 140) / 2,
                480,
                140,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                module,
                std::ptr::null(),
            );
            ensure!(
                !window.is_null(),
                "Cannot display runtime preparation progress"
            );
            let label = CreateWindowExW(
                0,
                wide("STATIC").as_ptr(),
                wide("正在准备运行环境，请稍候…\nPreparing the runtime. Please wait…").as_ptr(),
                WS_CHILD | WS_VISIBLE | 1,
                16,
                25,
                440,
                65,
                window,
                std::ptr::null_mut(),
                module,
                std::ptr::null(),
            );
            SendMessageW(
                label,
                WM_SETFONT,
                GetStockObject(DEFAULT_GUI_FONT) as usize,
                1,
            );
            UpdateWindow(window);
            Ok(Self {
                window,
                label,
                last: 0,
            })
        }
    }
    fn update(&mut self, current: usize, total: usize) -> Result<()> {
        use windows_sys::Win32::UI::WindowsAndMessaging::*;
        if self.window.is_null() {
            return Ok(());
        }
        unsafe {
            ensure!(IsWindow(self.window) != 0, "启动已取消 / Startup cancelled");
            let percent = current * 100 / total.max(1);
            if percent != self.last {
                self.last = percent;
                SetWindowTextW(
                    self.label,
                    wide(&format!(
                        "正在准备运行环境 {percent}%\nPreparing runtime {current}/{total}"
                    ))
                    .as_ptr(),
                );
            }
            let mut message = std::mem::zeroed();
            while PeekMessageW(&mut message, std::ptr::null_mut(), 0, 0, PM_REMOVE) != 0 {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
        Ok(())
    }
}
#[cfg(windows)]
impl Drop for Progress {
    fn drop(&mut self) {
        if !self.window.is_null() {
            unsafe {
                windows_sys::Win32::UI::WindowsAndMessaging::DestroyWindow(self.window);
            }
        }
    }
}
#[cfg(not(windows))]
struct Progress;
#[cfg(not(windows))]
impl Progress {
    fn new() -> Result<Self> {
        Ok(Self)
    }
    fn update(&mut self, _: usize, _: usize) -> Result<()> {
        Ok(())
    }
}
#[cfg(windows)]
fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(Some(0)).collect()
}
fn profile(cache: &Path) -> Result<PathBuf> {
    if let Some(path) = std::env::var_os("CPV_PROFILE") {
        let path = PathBuf::from(path);
        ensure!(
            writable(&path),
            "配置目录无法写入 / Profile is not writable"
        );
        return Ok(path.canonicalize()?);
    }
    let mut candidates = Vec::new();
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        candidates.push(PathBuf::from(local).join("CPV/RustProfile"));
    }
    candidates.push(
        std::env::current_exe()?
            .parent()
            .unwrap()
            .join(".CPV/Profile"),
    );
    candidates.push(cache.parent().unwrap_or(cache).join("RustProfile"));
    for path in candidates {
        if writable(&path) {
            return Ok(path.canonicalize()?);
        }
    }
    bail!("没有可写的配置目录 / No writable profile directory")
}
fn run() -> Result<()> {
    let digest = hash(PAYLOAD);
    let cache = cache()?;
    let (runtime, files) = expand(&cache, &digest[..20])?;
    if let Some(path) = std::env::var_os("CPV_BUNDLE_VERIFY") {
        cpv_core::write_json(
            Path::new(&path),
            &json!({"ok":true,"runtime":runtime,"files":files,"payload_sha256":digest}),
        )?;
        return Ok(());
    }
    let profile = profile(&cache)?;
    let logdir = diagnostics::directory(&profile);
    let detailed = std::env::args().any(|arg| arg == "--diagnostic")
        || std::env::var("CPV_DIAGNOSTICS").as_deref() == Ok("1")
        || cpv_core::read_json(&profile.join("cpv-settings.json"))
            .ok()
            .is_some_and(|v| v["diagnostics"] == true);
    diagnostics::record(
        &logdir,
        "launcher.jsonl",
        "launcher_start",
        json!({"version":diagnostics::VERSION,"payload_sha256":digest,"verified_files":files,"diagnostic_mode":detailed}),
    );
    let mut command = Command::new(runtime.join("自定义星球和变种.exe"));
    command
        .current_dir(&runtime)
        .env("CPV_PROFILE", &profile)
        .env("CPV_DIAGNOSTIC_DIR", &logdir);
    if detailed {
        command.env("CPV_DIAGNOSTICS", "1");
        command
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
    }
    let result = (|| -> Result<i32> {
        let mut child = command.spawn()?;
        let mut readers = Vec::new();
        fn reader<R: std::io::Read + Send + 'static>(
            input: R,
            dir: PathBuf,
            stream: &'static str,
        ) -> std::thread::JoinHandle<()> {
            std::thread::spawn(move || {
                use std::io::BufRead;
                for line in std::io::BufReader::new(input).split(b'\n') {
                    if let Ok(line) = line {
                        let text = String::from_utf8_lossy(&line);
                        diagnostics::record(
                            &dir,
                            "ui.jsonl",
                            stream,
                            json!({"message":diagnostics::safe(&text)}),
                        );
                    } else {
                        break;
                    }
                }
            })
        }
        if let Some(out) = child.stdout.take() {
            readers.push(reader(out, logdir.clone(), "native_stdout"));
        }
        if let Some(err) = child.stderr.take() {
            readers.push(reader(err, logdir.clone(), "native_stderr"));
        }
        let code = child.wait()?.code().unwrap_or(1);
        for task in readers {
            let _ = task.join();
        }
        Ok(code)
    })();
    diagnostics::record(
        &logdir,
        "launcher.jsonl",
        "application_exit",
        json!({"code":result.as_ref().ok(),"error":result.as_ref().err().map(|e|diagnostics::safe(&e.to_string()))}),
    );
    let code =
        result.with_context(|| format!("诊断日志 / Diagnostic logs: {}", logdir.display()))?;
    ensure!(code == 0, "程序异常退出 / Application exited: {code}");
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        if let Some(path) = std::env::var_os("CPV_BUNDLE_VERIFY") {
            let _ = cpv_core::write_json(
                Path::new(&path),
                &json!({"ok":false,"error":format!("{error:#}")}),
            );
        } else {
            #[cfg(windows)]
            unsafe {
                windows_sys::Win32::UI::WindowsAndMessaging::MessageBoxW(
                    std::ptr::null_mut(),
                    wide(&format!("启动失败 / Unable to start\n\n{error:#}")).as_ptr(),
                    wide("自定义星球和变种").as_ptr(),
                    0x10,
                );
            }
        }
        std::process::exit(1);
    }
}
