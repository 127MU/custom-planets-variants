use anyhow::{Result, ensure};
use base64::Engine;
use sha1::{Digest, Sha1};
use std::{
    path::Path,
    process::{Child, Command},
};

pub fn hidden(command: &mut Command) -> &mut Command {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
    command
}
fn certificate_der(bytes: &[u8]) -> Result<Vec<u8>> {
    ensure!(
        bytes.len() <= 64 * 1024,
        "证书文件过大 / Certificate file is too large"
    );
    if bytes.first() == Some(&0x30) {
        return Ok(bytes.to_vec());
    }
    let text = std::str::from_utf8(bytes)?;
    let encoded = text
        .split("-----BEGIN CERTIFICATE-----")
        .nth(1)
        .and_then(|s| s.split("-----END CERTIFICATE-----").next())
        .ok_or_else(|| anyhow::anyhow!("证书格式无效 / Invalid certificate format"))?;
    Ok(base64::engine::general_purpose::STANDARD
        .decode(encoded.split_whitespace().collect::<String>())?)
}
pub fn thumbprint(cert: &Path) -> Result<String> {
    Ok(format!(
        "{:x}",
        Sha1::digest(certificate_der(&std::fs::read(cert)?)?)
    ))
}
#[cfg(windows)]
struct CertificateStore(windows_sys::Win32::Security::Cryptography::HCERTSTORE);
#[cfg(windows)]
impl CertificateStore {
    fn current_user(read_only: bool) -> Result<Self> {
        use windows_sys::Win32::Security::Cryptography::*;
        let root: Vec<u16> = "ROOT\0".encode_utf16().collect();
        let flags = CERT_SYSTEM_STORE_CURRENT_USER
            | CERT_STORE_OPEN_EXISTING_FLAG
            | if read_only {
                CERT_STORE_READONLY_FLAG
            } else {
                0
            };
        let store =
            unsafe { CertOpenStore(CERT_STORE_PROV_SYSTEM_W, 0, 0, flags, root.as_ptr().cast()) };
        ensure!(
            !store.is_null(),
            "无法打开当前用户证书库 / Cannot open the current user certificate store: {}",
            std::io::Error::last_os_error()
        );
        Ok(Self(store))
    }
    fn find(
        &self,
        thumb: &str,
    ) -> Result<*mut windows_sys::Win32::Security::Cryptography::CERT_CONTEXT> {
        use windows_sys::Win32::Security::Cryptography::*;
        ensure!(
            thumb.len() == 40 && thumb.is_ascii() && thumb.chars().all(|c| c.is_ascii_hexdigit()),
            "Invalid certificate thumbprint"
        );
        let mut bytes: Vec<u8> = (0..40)
            .step_by(2)
            .map(|i| u8::from_str_radix(&thumb[i..i + 2], 16).unwrap())
            .collect();
        let hash = CRYPT_INTEGER_BLOB {
            cbData: 20,
            pbData: bytes.as_mut_ptr(),
        };
        let found = unsafe {
            CertFindCertificateInStore(
                self.0,
                X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
                0,
                CERT_FIND_SHA1_HASH,
                (&hash as *const CRYPT_INTEGER_BLOB).cast(),
                std::ptr::null(),
            )
        };
        Ok(found)
    }
    fn contains(&self, thumb: &str) -> Result<bool> {
        let found = self.find(thumb)?;
        if found.is_null() {
            return Ok(false);
        }
        unsafe {
            windows_sys::Win32::Security::Cryptography::CertFreeCertificateContext(found);
        }
        Ok(true)
    }
    fn add(&self, der: &[u8]) -> Result<()> {
        use windows_sys::Win32::Security::Cryptography::*;
        let result = unsafe {
            CertAddEncodedCertificateToStore(
                self.0,
                X509_ASN_ENCODING,
                der.as_ptr(),
                der.len() as u32,
                CERT_STORE_ADD_REPLACE_EXISTING,
                std::ptr::null_mut(),
            )
        };
        ensure!(
            result != 0,
            "Windows 未能信任证书 / Windows could not trust the certificate: {}",
            std::io::Error::last_os_error()
        );
        Ok(())
    }
    fn remove(&self, thumb: &str) -> Result<()> {
        let found = self.find(thumb)?;
        if found.is_null() {
            return Ok(());
        }
        let result = unsafe {
            windows_sys::Win32::Security::Cryptography::CertDeleteCertificateFromStore(found)
        };
        ensure!(
            result != 0,
            "Windows 未能移除证书 / Windows could not remove the certificate: {}",
            std::io::Error::last_os_error()
        );
        Ok(())
    }
}
#[cfg(windows)]
impl Drop for CertificateStore {
    fn drop(&mut self) {
        unsafe {
            windows_sys::Win32::Security::Cryptography::CertCloseStore(self.0, 0);
        }
    }
}
/// Certificate operations run on a dedicated thread under this process's own
/// user identity. No other user's token, privilege elevation or machine store.
#[cfg(windows)]
fn certificate_operation<T: Send + 'static>(
    operation: impl FnOnce() -> Result<T> + Send + 'static,
) -> Result<T> {
    struct Identity;
    impl Drop for Identity {
        fn drop(&mut self) {
            if unsafe { windows_sys::Win32::Security::RevertToSelf() } == 0 {
                // Never continue after a failed security-context restoration.
                eprintln!("Fatal: unable to restore certificate thread identity");
                std::process::abort();
            }
        }
    }
    std::thread::Builder::new().name("cpv-certificate".into()).spawn(move||{
        let ok=unsafe{windows_sys::Win32::Security::ImpersonateSelf(windows_sys::Win32::Security::SecurityImpersonation)};
        ensure!(ok!=0,"无法初始化当前用户证书操作上下文 / Cannot initialize the current-user certificate context: {}",std::io::Error::last_os_error());
        let _identity=Identity;
        operation()
    })?.join().map_err(|_|anyhow::anyhow!("证书操作线程异常 / Certificate worker failed"))?
}
#[cfg(windows)]
pub fn trusted(cert: &Path) -> bool {
    let Ok(thumb) = thumbprint(cert) else {
        return false;
    };
    certificate_operation(move || CertificateStore::current_user(true)?.contains(&thumb))
        .unwrap_or(false)
}
#[cfg(not(windows))]
pub fn trusted(_: &Path) -> bool {
    false
}
#[cfg(windows)]
pub fn install_certificate(cert: &Path) -> Result<()> {
    let der = certificate_der(&std::fs::read(cert)?)?;
    certificate_operation(move || {
        let thumb = format!("{:x}", Sha1::digest(&der));
        let store = CertificateStore::current_user(false)?;
        if !store.contains(&thumb)? {
            store.add(&der)?;
        }
        drop(store);
        ensure!(
            CertificateStore::current_user(true)?.contains(&thumb)?,
            "证书写入后未能验证；可能受到 Windows 策略限制 / Certificate verification failed after installation; check Windows policy"
        );
        Ok(())
    })
}
#[cfg(windows)]
pub fn remove_certificate(thumb: &str) -> Result<()> {
    let thumb = thumb.to_string();
    certificate_operation(move || CertificateStore::current_user(false)?.remove(&thumb))
}
#[cfg(not(windows))]
pub fn install_certificate(_: &Path) -> Result<()> {
    anyhow::bail!("Windows only")
}
#[cfg(not(windows))]
pub fn remove_certificate(_: &str) -> Result<()> {
    anyhow::bail!("Windows only")
}

#[cfg(windows)]
pub struct Job(windows_sys::Win32::Foundation::HANDLE);
#[cfg(windows)]
impl Job {
    pub fn new(child: &Child) -> Result<Self> {
        use std::os::windows::io::AsRawHandle;
        use windows_sys::Win32::{Foundation::*, System::JobObjects::*};
        unsafe {
            let handle = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            ensure!(!handle.is_null(), "Cannot create process job");
            let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if SetInformationJobObject(
                handle,
                JobObjectExtendedLimitInformation,
                (&info as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
                std::mem::size_of_val(&info) as u32,
            ) == 0
                || AssignProcessToJobObject(handle, child.as_raw_handle().cast()) == 0
            {
                CloseHandle(handle);
                anyhow::bail!("无法建立进程退出保护 / Cannot protect proxy lifetime");
            }
            Ok(Self(handle))
        }
    }
}
#[cfg(windows)]
impl Drop for Job {
    fn drop(&mut self) {
        unsafe {
            windows_sys::Win32::Foundation::CloseHandle(self.0);
        }
    }
}
#[cfg(not(windows))]
pub struct Job;
#[cfg(not(windows))]
impl Job {
    pub fn new(_: &Child) -> Result<Self> {
        Ok(Self)
    }
}

#[cfg(windows)]
pub fn process_started(pid: u32) -> Result<u64> {
    use windows_sys::Win32::{Foundation::*, System::Threading::*};
    unsafe {
        let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        ensure!(!h.is_null(), "Cannot query proxy process");
        let mut c: FILETIME = std::mem::zeroed();
        let mut e = c;
        let mut k = c;
        let mut u = c;
        let ok = GetProcessTimes(h, &mut c, &mut e, &mut k, &mut u);
        CloseHandle(h);
        ensure!(ok != 0, "Cannot query proxy session");
        Ok((u64::from(c.dwHighDateTime) << 32) | u64::from(c.dwLowDateTime))
    }
}
#[cfg(not(windows))]
pub fn process_started(_: u32) -> Result<u64> {
    Ok(0)
}

pub fn open_steam() -> Result<()> {
    #[cfg(windows)]
    {
        ensure!(
            !game_running(),
            "请先完全退出游戏，再重新通过 Steam 启动 / Fully exit the game before launching through Steam again"
        );
        use windows_sys::Win32::UI::Shell::ShellExecuteW;
        let verb: Vec<u16> = "open\0".encode_utf16().collect();
        let uri: Vec<u16> = "steam://rungameid/553850\0".encode_utf16().collect();
        ensure!(
            unsafe {
                ShellExecuteW(
                    std::ptr::null_mut(),
                    verb.as_ptr(),
                    uri.as_ptr(),
                    std::ptr::null(),
                    std::ptr::null(),
                    1,
                )
            } as isize
                > 32,
            "无法启动 Steam / Cannot open Steam"
        );
    }
    Ok(())
}

#[cfg(windows)]
fn game_running() -> bool {
    use windows_sys::Win32::{Foundation::*, System::Diagnostics::ToolHelp::*};
    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snapshot == INVALID_HANDLE_VALUE {
            return false;
        }
        let mut entry: PROCESSENTRY32W = std::mem::zeroed();
        entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
        let mut more = Process32FirstW(snapshot, &mut entry);
        let mut found = false;
        while more != 0 {
            let len = entry
                .szExeFile
                .iter()
                .position(|c| *c == 0)
                .unwrap_or(entry.szExeFile.len());
            if String::from_utf16_lossy(&entry.szExeFile[..len])
                .eq_ignore_ascii_case("helldivers2.exe")
            {
                found = true;
                break;
            }
            more = Process32NextW(snapshot, &mut entry);
        }
        CloseHandle(snapshot);
        found
    }
}
pub fn upstream() -> Result<Option<String>> {
    let output = hidden(Command::new("reg").args([
        "query",
        r"HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings",
    ]))
    .output()?;
    let text = String::from_utf8_lossy(&output.stdout);
    let enabled = text
        .lines()
        .any(|l| l.contains("ProxyEnable") && l.split_whitespace().last() == Some("0x1"));
    if !enabled {
        return Ok(None);
    }
    let line = text
        .lines()
        .find(|l| l.trim_start().starts_with("ProxyServer "))
        .unwrap_or("");
    let mut value = line.split("REG_SZ").nth(1).unwrap_or("").trim().to_string();
    if value.contains('=') {
        value = value
            .split(';')
            .find_map(|p| p.strip_prefix("http="))
            .unwrap_or("")
            .to_string();
    }
    if value.is_empty() {
        return Ok(None);
    }
    ensure!(
        !value
            .chars()
            .any(|c| c.is_whitespace() || "@/?#".contains(c))
            || value.starts_with("http://")
            || value.starts_with("https://"),
        "系统 HTTP 代理格式无效 / Invalid upstream proxy"
    );
    let address = if value.contains("://") {
        value
    } else {
        format!("http://{value}")
    };
    ensure!(
        address.starts_with("http://") || address.starts_with("https://"),
        "仅支持 HTTP 上游代理 / Only HTTP upstream proxies are supported"
    );
    ensure!(
        !address
            .split("://")
            .nth(1)
            .unwrap_or("")
            .contains(['@', '/', '?', '#']),
        "系统 HTTP 代理不支持认证或路径 / Unsupported upstream proxy"
    );
    Ok(Some(address))
}

#[cfg(test)]
mod certificate_tests {
    use super::*;
    #[test]
    fn public_pem_and_der_have_the_same_thumbprint() {
        let pem = include_bytes!("test-ca.pem");
        let der = certificate_der(pem).unwrap();
        assert_eq!(der, certificate_der(&der).unwrap());
        assert!(certificate_der(b"invalid certificate").is_err());
    }
    #[cfg(windows)]
    #[test]
    fn certificate_worker_uses_own_impersonation_context_and_restores() {
        certificate_operation(|| {
            use windows_sys::Win32::{Foundation::*, Security::*, System::Threading::*};
            let mut token = std::ptr::null_mut();
            assert_ne!(
                unsafe { OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, 1, &mut token) },
                0
            );
            let mut level: i32 = -1;
            let mut length = 0;
            let ok = unsafe {
                GetTokenInformation(
                    token,
                    TokenImpersonationLevel,
                    (&mut level as *mut i32).cast(),
                    4,
                    &mut length,
                )
            };
            unsafe {
                CloseHandle(token);
            }
            assert_ne!(ok, 0);
            assert_eq!(level, SecurityImpersonation);
            let store = CertificateStore::current_user(true)?;
            drop(store);
            Ok(())
        })
        .unwrap();
        let error =
            certificate_operation(|| -> Result<()> { anyhow::bail!("test failure") }).unwrap_err();
        assert!(error.to_string().contains("test failure"));
    }
    #[cfg(windows)]
    #[test]
    fn add_find_remove_in_memory_never_touches_user_trust() {
        use windows_sys::Win32::Security::Cryptography::*;
        let handle = unsafe { CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, 0, std::ptr::null()) };
        assert!(!handle.is_null());
        let store = CertificateStore(handle);
        let der = certificate_der(include_bytes!("test-ca.pem")).unwrap();
        let thumb = format!("{:x}", Sha1::digest(&der));
        assert!(!store.contains(&thumb).unwrap());
        store.add(&der).unwrap();
        assert!(store.contains(&thumb).unwrap());
        store.add(&der).unwrap();
        store.remove(&thumb).unwrap();
        assert!(!store.contains(&thumb).unwrap());
    }
}
