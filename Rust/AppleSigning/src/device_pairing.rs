//! Device-initiated pairing using the MIT-licensed idevice responder API.
//! Credentials are returned in-process to the Swift keychain owner, never logged.
use std::{collections::HashMap, ffi::{c_char, c_void, CStr, CString}, sync::{atomic::{AtomicU64, Ordering}, Mutex, OnceLock}, time::Duration};
use base64::{Engine, prelude::BASE64_STANDARD};
use idevice::remote_pairing::{PairableHost, PairableHostInfo, PeerDevice, RemotePairingClient, RpPairingFile, RpPairingSocket};
use serde_json::{json, Value};
use tokio::{net::TcpListener, sync::oneshot};
use futures_util::FutureExt;

type EventCallback = extern "C" fn(*const c_char, *mut c_void);
#[derive(Clone, Copy)]
struct Events { callback: EventCallback, context: usize }
impl Events {
    fn send(self, value: Value) {
        if let Ok(text) = CString::new(value.to_string()) { (self.callback)(text.as_ptr(), self.context as *mut c_void); }
    }
}
fn sessions() -> &'static Mutex<HashMap<u64, oneshot::Sender<()>>> {
    static SESSIONS: OnceLock<Mutex<HashMap<u64, oneshot::Sender<()>>>> = OnceLock::new();
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}
async fn pair(request: Value, events: Events) -> Result<Value, String> {
    let mut record = match request["record"].as_str().filter(|s| !s.is_empty()) {
        Some(text) => {
            let bytes = BASE64_STANDARD.decode(text).map_err(|_| "无法读取已保存的配对身份")?;
            RpPairingFile::from_bytes(&bytes).map_err(|_| "已保存的配对身份无效，请重新导入")?
        }
        None => {
            let nonce = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_err(|_| "系统时间无效")?.as_nanos();
            RpPairingFile::generate(&format!("Retools-{nonce}"))
        },
    };
    if record.e_private_key.verifying_key() != record.e_public_key { return Err("配对身份的公私钥不匹配".into()); }
    record.alt_irk = None;
    let mut info = PairableHostInfo::generate("Retools", "Mac17,7");
    info.identifier = record.identifier().to_string();
    info.udid = record.identifier().to_string();
    if let Some(saved) = request["host_irk"].as_str().and_then(|s| BASE64_STANDARD.decode(s).ok()) {
        if saved.len() == 16 { info.alt_irk.copy_from_slice(&saved); }
    }
    let host_irk = info.alt_irk;
    let listener = TcpListener::bind((std::net::Ipv4Addr::UNSPECIFIED, 0)).await.map_err(|e| format!("无法启动配对监听：{e}"))?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let txt: HashMap<String, String> = info.mdns_txt_records(record.identifier()).into_iter().collect();
    events.send(json!({"type":"ready", "identifier":record.identifier(), "port":port, "txt":txt}));
    let (stream, _) = listener.accept().await.map_err(|e| format!("配对连接未建立：{e}"))?;
    events.send(json!({"type":"connected"}));
    let mut host = PairableHost::new(RpPairingSocket::new_device(stream), info);
    let peer = host.accept(&mut record, move |pin| async move {
        events.send(json!({"type":"pin", "pin":pin}));
    }).await.map_err(|e| format!("设备配对未完成：{e}"))?;
    // Keep the responder alive briefly while Settings commits the trusted host.
    tokio::time::sleep(Duration::from_millis(800)).await;
    Ok(json!({"type":"completed", "record":BASE64_STANDARD.encode(record.to_bytes()),
              "host_irk":BASE64_STANDARD.encode(host_irk), "udid":peer.remotepairing_udid,
              "device_name":peer.name, "device_model":peer.model}))
}

/// Non-interactive pair-verify only. Never falls back to a new PIN pairing.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_device_pairing_verify(record: *const u8, length: usize, host: *const c_char, port: u16) -> *mut c_char {
    crate::respond(|| {
        if record.is_null() || host.is_null() || length > 2_000_000 || port == 0 { rootcause::bail!("设备连接参数无效"); }
        let bytes = unsafe { std::slice::from_raw_parts(record, length) };
        let mut record = RpPairingFile::from_bytes(bytes).map_err(|_| rootcause::report!("配对身份格式无效"))?;
        if record.e_private_key.verifying_key() != record.e_public_key { rootcause::bail!("配对身份公私钥不匹配"); }
        let host: std::net::IpAddr = unsafe { CStr::from_ptr(host) }.to_str()?.parse()?;
        crate::runtime().block_on(async move {
            tokio::time::timeout(Duration::from_secs(15), async move {
                let stream = tokio::net::TcpStream::connect(std::net::SocketAddr::new(host, port)).await?;
                let mut client = RemotePairingClient::new(RpPairingSocket::new(stream), "Retools");
                client.attempt_pair_verify().await?;
                client.validate_pairing(&mut record).await?;
                Ok::<Value, rootcause::Report>(json!({"ok":true}))
            }).await.map_err(|_| rootcause::report!("设备配对验证超时"))?
        })
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_device_pairing_start(request: *const c_char, callback: Option<EventCallback>, context: *mut c_void) -> u64 {
    let Some(callback) = callback else { return 0; };
    if request.is_null() { return 0; }
    let text = unsafe { CStr::from_ptr(request) }.to_string_lossy();
    if text.len() > 3_000_000 { return 0; }
    let Ok(request) = serde_json::from_str::<Value>(&text) else { return 0; };
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    let (cancel, cancelled) = oneshot::channel();
    sessions().lock().unwrap_or_else(|p| p.into_inner()).insert(id, cancel);
    let events = Events { callback, context: context as usize };
    crate::runtime().spawn(async move {
        let result = tokio::select! {
            _ = cancelled => json!({"type":"cancelled"}),
            value = tokio::time::timeout(Duration::from_secs(300), std::panic::AssertUnwindSafe(pair(request, events)).catch_unwind()) => match value {
                Ok(Ok(Ok(value))) => value,
                Ok(Ok(Err(error))) => json!({"type":"failed", "error":error}),
                Ok(Err(_)) => json!({"type":"failed", "error":"配对引擎已结束，请重试"}),
                Err(_) => json!({"type":"failed", "error":"配对等待超时，请返回 Retools 重试"}),
            }
        };
        sessions().lock().unwrap_or_else(|p| p.into_inner()).remove(&id);
        events.send(result);
    });
    id
}

#[unsafe(no_mangle)]
pub extern "C" fn rt_device_pairing_cancel(id: u64) {
    if let Some(cancel) = sessions().lock().unwrap_or_else(|p| p.into_inner()).remove(&id) { let _ = cancel.send(()); }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_device_pairing_matches(record: *const u8, length: usize, identifier: *const c_char, tag: *const c_char) -> bool {
    if record.is_null() || identifier.is_null() || tag.is_null() || length > 2_000_000 { return false; }
    let Ok(record) = RpPairingFile::from_bytes(unsafe { std::slice::from_raw_parts(record, length) }) else { return false; };
    let Some(irk) = record.alt_irk() else { return false; };
    if record.e_private_key.verifying_key() != record.e_public_key { return false; }
    PeerDevice::validate_auth_tag(irk, &unsafe { CStr::from_ptr(identifier) }.to_string_lossy(), &unsafe { CStr::from_ptr(tag) }.to_string_lossy())
}
