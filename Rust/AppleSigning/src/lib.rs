use std::{collections::{HashMap, HashSet}, ffi::{CStr, CString, c_char, c_void}, sync::{Arc, Mutex, OnceLock}, time::{Duration, Instant}};
use base64::{Engine, prelude::BASE64_STANDARD};
use rootcause::prelude::*;
use serde_json::{Value, json};
use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, AppToken, TwoFactorCallbackResponse},
    dev::{developer_session::{DeveloperSession, AppIdsApi, AppGroupsApi, CertificatesApi, DevicesApi, TeamsApi}, device_type::{DeveloperDeviceType, dev_url}, app_ids::AppId, app_groups::AppGroup, teams::DeveloperTeam},
    sideload::{cert_identity::CertificateIdentity, builder::MaxCertsBehavior},
    util::{storage::SideloadingStorage, callbacks::MaxCertsCallbackBox},
};
mod device_pairing;

type TwoFactor = extern "C" fn(*const c_char, *mut c_void) -> *mut c_char;
#[derive(Clone)]
struct Vault(Arc<Mutex<HashMap<String, String>>>);
impl Vault {
    fn from_request(request: &Value) -> Result<Self, Report> {
        let values = serde_json::from_value(request.get("state").cloned().unwrap_or(json!({})))?;
        Ok(Self(Arc::new(Mutex::new(values))))
    }
    fn json(&self) -> Value { json!(self.snapshot()) }
    fn snapshot(&self) -> HashMap<String, String> { self.0.lock().unwrap_or_else(|p| p.into_inner()).clone() }
    fn replace(&self, values: HashMap<String, String>) { *self.0.lock().unwrap_or_else(|p| p.into_inner()) = values; }
}
impl SideloadingStorage for Vault {
    fn store(&self, key: &str, value: &str) -> Result<(), Report> {
        self.0.lock().unwrap_or_else(|p| p.into_inner()).insert(key.into(), value.into()); Ok(())
    }
    fn retrieve(&self, key: &str) -> Result<Option<String>, Report> {
        Ok(self.0.lock().unwrap_or_else(|p| p.into_inner()).get(key).cloned())
    }
}
fn field<'a>(request: &'a Value, key: &str) -> Result<&'a str, Report> {
    request[key].as_str().ok_or_else(|| report!("Missing field: {}", key))
}
fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        // reqwest uses rustls-no-provider: configure TLS before building any client.
        let _ = rustls::crypto::ring::default_provider().install_default();
        tokio::runtime::Builder::new_multi_thread().thread_stack_size(4 * 1024 * 1024).enable_all().build().expect("Tokio runtime")
    })
}
async fn make_account(request: &Value, vault: Vault) -> Result<AppleAccount, Report> {
    let url = field(request, "anisette_url")?;
    if !url.starts_with("https://") { bail!("Anisette must use HTTPS"); }
    let provider = RemoteV3AnisetteProvider::new(url, Box::new(vault), "0".into())?;
    Ok(tokio::time::timeout(Duration::from_secs(60),
        AppleAccount::builder(field(request, "email")?).anisette_provider(provider).err_429_retries(Some(2)).build())
        .await.context("连接 Anisette 或 Apple 验证服务超时，请检查网络或更换 Anisette 服务")?
        .context("无法准备 Apple ID 验证服务")?)
}
async fn login(request: Value, vault: Vault, callback: Option<TwoFactor>, context: usize) -> Result<Value, Report> {
    let mut account = make_account(&request, vault.clone()).await?;
    account.login(field(&request, "password")?, move |params| async move {
        let Some(callback) = callback else { return Ok(TwoFactorCallbackResponse::Abort); };
        let prompt = CString::new(serde_json::to_string(&params)?)?;
        let raw = callback(prompt.as_ptr(), context as *mut c_void);
        if raw.is_null() { return Ok(TwoFactorCallbackResponse::Abort); }
        let answer = unsafe { CStr::from_ptr(raw) }.to_string_lossy().into_owned();
        unsafe { libc::free(raw as *mut c_void) };
        let answer: Value = serde_json::from_str(&answer)?;
        Ok(match answer["action"].as_str() {
            Some("code") => TwoFactorCallbackResponse::SubmitCode(answer["code"].as_str().unwrap_or("").into()),
            Some("sms") => TwoFactorCallbackResponse::SendSms(answer["id"].as_u64().unwrap_or(0) as u32),
            Some("devices") => TwoFactorCallbackResponse::SendToDevices,
            Some("resend") => TwoFactorCallbackResponse::ResendCode,
            _ => TwoFactorCallbackResponse::Abort,
        })
    }).await.context("Apple ID 账号验证未完成")?;
    let token = account.get_app_token("xcode.auth").await.context("无法取得 Apple 开发者登录会话")?;
    let adsid = account.spd.as_ref().and_then(|v| v.get("adsid")).and_then(|v| v.as_string()).ok_or_else(|| report!("Apple did not return an account identifier"))?.to_string();
    vault.store("retools_auth", &json!({"token":token.token,"duration":token.duration,"expiry":token.expiry,"adsid":adsid}).to_string())?;
    let mut session = DeveloperSession::new(token, adsid, account.grandslam_client.clone(), account.anisette_generator.clone());
    let teams = session.list_teams().await.context("Apple ID 已验证，但无法读取开发者团队")?;
    let teams: Vec<Value> = teams.into_iter().map(|team| json!({"id":team.team_id,"name":team.name.unwrap_or_default(),"type":team.r#type.unwrap_or_default()})).collect();
    Ok(json!({"ok":true,"teams":teams,"state":vault.json()}))
}
/// A developer session kept between profile requests of one renewal batch, like
/// SideStore: one sign-in context, then only per-app App ID/profile requests.
/// Teams, device registration, the signing certificate and the App ID list are
/// fetched once per session.
struct CachedSession {
    vault: Vault,
    session: DeveloperSession,
    created: Instant,
    /// Account state returned to the caller after the last successful request.
    /// The session is reused only when the next request carries exactly this
    /// state, so sign-in, Anisette reset or sign-out start a new session.
    returned_state: HashMap<String, String>,
    teams: Option<Vec<DeveloperTeam>>,
    registered_devices: HashSet<(String, String)>,
    identities: HashMap<String, CertificateIdentity>,
    app_ids: HashMap<String, Vec<AppId>>,
    /// Remaining App ID registrations per team, as reported with the App ID list.
    available_app_ids: HashMap<String, Option<i64>>,
    app_groups: HashMap<String, Vec<AppGroup>>,
}
const SESSION_TTL: Duration = Duration::from_secs(10 * 60);
type SessionSlot = Arc<tokio::sync::Mutex<Option<CachedSession>>>;
fn session_slot(key: String) -> SessionSlot {
    static SLOTS: OnceLock<Mutex<HashMap<String, SessionSlot>>> = OnceLock::new();
    SLOTS.get_or_init(Default::default).lock().unwrap_or_else(|p| p.into_inner()).entry(key).or_default().clone()
}
async fn open_session(request: &Value, vault: Vault) -> Result<CachedSession, Report> {
    let account = make_account(request, vault.clone()).await?;
    let saved = vault.retrieve("retools_auth")?.ok_or_else(|| report!("Please sign in to Apple ID first"))?;
    let saved: Value = serde_json::from_str(&saved)?;
    let token = AppToken { token:field(&saved,"token")?.into(), duration:saved["duration"].as_u64().unwrap_or(0), expiry:saved["expiry"].as_u64().unwrap_or(0) };
    let session = DeveloperSession::new(token, field(&saved,"adsid")?.into(), account.grandslam_client.clone(), account.anisette_generator.clone());
    Ok(CachedSession { vault, session, created: Instant::now(), returned_state: HashMap::new(), teams: None,
        registered_devices: HashSet::new(), identities: HashMap::new(), app_ids: HashMap::new(),
        available_app_ids: HashMap::new(), app_groups: HashMap::new() })
}
/// Teams, device registration, signing certificate and the App ID list: fetched once per session.
async fn prepare_team(request: &Value, cached: &mut CachedSession) -> Result<DeveloperTeam, Report> {
    if cached.teams.is_none() { cached.teams = Some(cached.session.list_teams().await?); }
    let team_id = request["team_id"].as_str().unwrap_or("");
    let team = cached.teams.iter().flatten().find(|t| t.team_id == team_id).cloned().ok_or_else(|| report!("Select a valid developer team"))?;
    let udid = field(request,"udid")?;
    let device = (team.team_id.clone(), udid.to_string());
    if !cached.registered_devices.contains(&device) {
        cached.session.ensure_device_registered(&team,"Retools iPhone",udid,DeveloperDeviceType::Ios).await?;
        cached.registered_devices.insert(device);
    }
    if !cached.identities.contains_key(&team.team_id) {
        // Never revoke other applications' certificates automatically.
        let behavior: MaxCertsBehavior<MaxCertsCallbackBox> = MaxCertsBehavior::Error;
        let identity = CertificateIdentity::retrieve("Retools",field(request,"email")?,&mut cached.session,&team,&cached.vault,&behavior).await
            .context("无法取得开发证书。如果提示证书数量已达上限，可在「Apple ID 自动续签 → 开发证书」撤销不用的证书后重试")?;
        cached.identities.insert(team.team_id.clone(), identity);
    }
    if !cached.app_ids.contains_key(&team.team_id) {
        let ids = cached.session.list_app_ids(&team,DeveloperDeviceType::Ios).await?;
        cached.available_app_ids.insert(team.team_id.clone(), ids.available_quantity);
        cached.app_ids.insert(team.team_id.clone(), ids.app_ids);
    }
    Ok(team)
}
fn known_app_id(cached: &CachedSession, team: &DeveloperTeam, bundle_id: &str) -> Option<AppId> {
    cached.app_ids.get(&team.team_id).and_then(|ids| ids.iter().find(|id| id.identifier == bundle_id).cloned())
}
async fn app_id_for(cached: &mut CachedSession, team: &DeveloperTeam, bundle_id: &str, name: &str) -> Result<AppId, Report> {
    if let Some(id) = known_app_id(cached, team, bundle_id) { return Ok(id); }
    let id = cached.session.add_app_id(team, name, bundle_id, DeveloperDeviceType::Ios).await?;
    cached.app_ids.entry(team.team_id.clone()).or_default().push(id.clone());
    if let Some(Some(available)) = cached.available_app_ids.get_mut(&team.team_id) { *available -= 1; }
    Ok(id)
}
fn p12_for<'a>(cached: &'a CachedSession, team: &DeveloperTeam) -> Result<&'a CertificateIdentity, Report> {
    cached.identities.get(&team.team_id).ok_or_else(|| report!("Signing certificate is unavailable"))
}
async fn profile_in(request: &Value, cached: &mut CachedSession) -> Result<Value, Report> {
    let team = prepare_team(request, cached).await?;
    let bundle_id = request["provisioning_bundle_id"].as_str().unwrap_or(field(request,"bundle_id")?);
    let app_id = app_id_for(cached, &team, bundle_id, field(request,"app_name")?).await?;
    let profile = cached.session.download_team_provisioning_profile(&team,&app_id,DeveloperDeviceType::Ios).await?;
    let p12 = p12_for(cached, &team)?.as_p12(field(request,"p12_password")?).await?;
    Ok(json!({"ok":true,"p12":BASE64_STANDARD.encode(p12),"profile":BASE64_STANDARD.encode(profile.encoded_profile.as_ref() as &[u8])}))
}

/// Team type as SideSign resolves it: one "free" program membership marks a free team.
fn team_kind(team: &DeveloperTeam) -> &'static str {
    match team.r#type.as_deref() {
        Some("Company/Organization") => "organization",
        Some("Individual") => {
            let memberships = team.memberships.as_deref().unwrap_or(&[]);
            if memberships.len() == 1 && memberships[0].name.as_deref().unwrap_or("").to_lowercase().contains("free") { "free" } else { "individual" }
        }
        _ => "unknown",
    }
}
/// Developer portal feature for an entitlement (SideSign's Feature table).
fn feature_for(entitlement: &str) -> Option<&'static str> {
    Some(match entitlement {
        "com.apple.security.application-groups" => "APG3427HIY",
        "inter-app-audio" => "IAD53UNK2F",
        "com.apple.developer.associated-domains" => "associatedDomains",
        "com.apple.developer.default-data-protection" => "dataProtection",
        "com.apple.developer.siri" => "siri",
        "com.apple.developer.in-app-payments" => "applePay",
        "com.apple.developer.networking.vpn.api" => "vpn",
        "com.apple.developer.networking.networkextension" => "networkExtensions",
        "com.apple.developer.networking.multipath" => "multipath",
        "com.apple.developer.networking.HotspotConfiguration" => "hotspot",
        "com.apple.developer.nfc.readersession.formats" => "nfc",
        "com.apple.developer.ClassKit-environment" => "classKit",
        "com.apple.developer.authentication-services.autofill-credential-provider" => "autoFillCredentialProvider",
        "com.apple.developer.networking.wifi-info" => "accessWiFiInformation",
        "com.apple.external-accessory.wireless-configuration" => "wirelessAccessoryConfiguration",
        "com.apple.developer.kernel.increased-memory-limit" => "increasedMemoryLimit",
        "com.apple.developer.kernel.extended-virtual-addressing" => "extendedVirtualAddressing",
        "com.apple.developer.kernel.increased-debugging-memory-limit" => "increasedDebuggingMemoryLimit",
        "aps-environment" => "push",
        "game-center" | "com.apple.developer.game-center" => "gameCenter",
        "in-app-purchase" => "inAppPurchase",
        _ => return None,
    })
}
const FREE_FEATURES: &[&str] = &["APG3427HIY", "IAD53UNK2F"];
const PAID_FEATURES: &[&str] = &["APG3427HIY", "IAD53UNK2F", "gameCenter", "inAppPurchase", "push", "associatedDomains", "dataProtection",
    "siri", "applePay", "vpn", "networkExtensions", "multipath", "hotspot", "nfc", "classKit", "autoFillCredentialProvider",
    "accessWiFiInformation", "wirelessAccessoryConfiguration", "increasedMemoryLimit", "extendedVirtualAddressing", "increasedDebuggingMemoryLimit"];
fn feature_enabled(app_id: &AppId, feature: &str) -> bool {
    match app_id.features.get(feature) {
        Some(plist::Value::Boolean(value)) => *value,
        Some(plist::Value::String(value)) => value == "true",
        _ => false,
    }
}

/// Provisioning for one app and its extensions, following SideStore's FetchProvisioningProfiles:
/// per bundle register the App ID, enable the features its entitlements need (App Groups always),
/// register its App Groups as "<group>.<team>" and assign them, then download that bundle's profile.
async fn app_profiles_in(request: &Value, cached: &mut CachedSession) -> Result<Value, Report> {
    let team = prepare_team(request, cached).await?;
    let kind = team_kind(&team);
    let allowed: &[&str] = if matches!(kind, "individual" | "organization") { PAID_FEATURES } else { FREE_FEATURES };
    let mut bundles: Vec<&Value> = request["bundles"].as_array().ok_or_else(|| report!("Missing bundles"))?.iter().collect();
    if bundles.is_empty() { bail!("Missing bundles"); }
    // Free accounts may only register a few App IDs per week. Like SideStore's extension
    // prompt, keep the main app and leave the extensions out when they would not fit.
    let missing = |bundles: &[&Value], cached: &CachedSession| bundles.iter().filter(|b| known_app_id(cached, &team, b["bundle_id"].as_str().unwrap_or("")).is_none()).count() as i64;
    let mut extensions_removed = false;
    if let Some(Some(available)) = cached.available_app_ids.get(&team.team_id).copied() {
        if missing(&bundles, cached) > available.max(0) {
            if bundles.len() > 1 && missing(&bundles[..1], cached) <= available.max(0) { bundles.truncate(1); extensions_removed = true; }
            else { bail!("可用 App ID 不足：还能注册 {} 个，需要 {} 个。免费账号每 7 天最多注册 10 个 App ID，可在开发者网站删除不用的 App ID 或稍后再试。", available.max(0), missing(&bundles, cached)); }
        }
    }
    let mut results = Vec::new();
    for bundle in bundles {
        let bundle_id = field(bundle, "bundle_id")?;
        let mut app_id = app_id_for(cached, &team, bundle_id, bundle["name"].as_str().unwrap_or("App")).await?;
        // Features: what this bundle's entitlements need, App Groups always (SideStore's mandatory feature).
        let mut wanted = plist::Dictionary::new();
        let keys = bundle["entitlement_keys"].as_array().map(|v| v.iter().filter_map(|k| k.as_str()).collect::<Vec<_>>()).unwrap_or_default();
        for feature in keys.iter().filter_map(|key| feature_for(key)).chain(["APG3427HIY"]) {
            if allowed.contains(&feature) && !feature_enabled(&app_id, feature) { wanted.insert(feature.to_string(), plist::Value::Boolean(true)); }
        }
        if !wanted.is_empty() {
            app_id = cached.session.update_app_id(&team, &app_id, wanted, DeveloperDeviceType::Ios).await.context("无法为 App ID 开启所需功能")?;
            if let Some(ids) = cached.app_ids.get_mut(&team.team_id) { if let Some(entry) = ids.iter_mut().find(|id| id.identifier == app_id.identifier) { *entry = app_id.clone(); } }
        }
        // App Groups: "<declared group>.<team>", created on the team when missing, then assigned together.
        let mut assigned = Vec::new();
        let declared: Vec<String> = bundle["app_groups"].as_array().map(|v| v.iter().filter_map(|g| g.as_str().map(String::from)).collect()).unwrap_or_default();
        if !declared.is_empty() {
            if !cached.app_groups.contains_key(&team.team_id) {
                let groups = cached.session.list_app_groups(&team, DeveloperDeviceType::Ios).await?;
                cached.app_groups.insert(team.team_id.clone(), groups);
            }
            let mut group_ids = Vec::new();
            for group in declared {
                if group.contains("$(") { bail!("App Group 含有未替换的占位符：{}", group); }
                let adjusted = if group.ends_with(&format!(".{}", team.team_id)) { group.clone() } else { format!("{}.{}", group, team.team_id) };
                if assigned.contains(&adjusted) { continue; }
                let existing = cached.app_groups.get(&team.team_id).and_then(|groups| groups.iter().find(|g| g.identifier == adjusted).cloned());
                let app_group = match existing {
                    Some(group) => group,
                    None => {
                        let created = cached.session.add_app_group(&team, &format!("Retools {}", group.replace('.', " ")), &adjusted, DeveloperDeviceType::Ios).await.context("无法注册 App Group")?;
                        cached.app_groups.entry(team.team_id.clone()).or_default().push(created.clone());
                        created
                    }
                };
                group_ids.push(plist::Value::String(app_group.application_group.clone()));
                assigned.push(adjusted);
            }
            let mut body = plist::Dictionary::new();
            body.insert("teamId".into(), plist::Value::String(team.team_id.clone()));
            body.insert("appIdId".into(), plist::Value::String(app_id.app_id_id.clone()));
            body.insert("applicationGroups".into(), plist::Value::Array(group_ids));
            cached.session.send_dev_request_no_response(&dev_url("assignApplicationGroupToAppId", DeveloperDeviceType::Ios), body).await.context("无法把 App Group 分配给 App ID")?;
        }
        let profile = cached.session.download_team_provisioning_profile(&team, &app_id, DeveloperDeviceType::Ios).await?;
        results.push(json!({"bundle_id": bundle_id, "profile": BASE64_STANDARD.encode(profile.encoded_profile.as_ref() as &[u8]), "app_groups": assigned}));
    }
    let p12 = p12_for(cached, &team)?.as_p12(field(request,"p12_password")?).await?;
    Ok(json!({"ok":true,"p12":BASE64_STANDARD.encode(p12),"profiles":results,"team_type":kind,"extensions_removed":extensions_removed}))
}

/// The team's App IDs as AltStore's "App IDs" screen shows them: every app and extension takes one,
/// free teams get at most 10 and each expires after 7 days. Read only; also refreshes the session cache.
async fn app_ids_in(request: &Value, cached: &mut CachedSession) -> Result<Value, Report> {
    if cached.teams.is_none() { cached.teams = Some(cached.session.list_teams().await?); }
    let team_id = request["team_id"].as_str().unwrap_or("");
    let team = cached.teams.iter().flatten().find(|t| t.team_id == team_id).cloned().ok_or_else(|| report!("Select a valid developer team"))?;
    let response = cached.session.list_app_ids(&team, DeveloperDeviceType::Ios).await?;
    let items: Vec<Value> = response.app_ids.iter().map(|id| {
        let expires = id.expiration_date.map(|date| std::time::SystemTime::from(date).duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0));
        json!({"identifier": id.identifier, "name": id.name, "expires": expires})
    }).collect();
    cached.available_app_ids.insert(team.team_id.clone(), response.available_quantity);
    cached.app_ids.insert(team.team_id.clone(), response.app_ids);
    Ok(json!({"ok":true, "app_ids": items, "max": response.max_quantity, "available": response.available_quantity, "team_type": team_kind(&team)}))
}

fn find_team(request: &Value, cached: &CachedSession) -> Result<DeveloperTeam, Report> {
    let team_id = request["team_id"].as_str().unwrap_or("");
    cached.teams.iter().flatten().find(|t| t.team_id == team_id).cloned().ok_or_else(|| report!("Select a valid developer team"))
}
/// The team's iOS development certificates (as SideStore's certificate list shows them). Read only.
async fn certificates_in(request: &Value, cached: &mut CachedSession) -> Result<Value, Report> {
    if cached.teams.is_none() { cached.teams = Some(cached.session.list_teams().await?); }
    let team = find_team(request, cached)?;
    let certificates = cached.session.list_ios_certs(&team).await?;
    let items: Vec<Value> = certificates.iter().map(|cert| {
        let expires = cert.expiration_date.map(|date| std::time::SystemTime::from(date).duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0));
        json!({"name": cert.name, "machine_name": cert.machine_name, "serial_number": cert.serial_number, "status": cert.status, "expires": expires,
               "content": cert.cert_content.as_ref().map(|data| BASE64_STANDARD.encode(data.as_ref() as &[u8]))})
    }).collect();
    let maximum = certificates.iter().filter_map(|c| c.certificate_type.as_ref().and_then(|t| t.max_active_certs)).max();
    Ok(json!({"ok": true, "certificates": items, "max": maximum, "team_type": team_kind(&team)}))
}
/// Revokes one development certificate by serial number. Apps signed with it stop launching.
async fn revoke_in(request: &Value, cached: &mut CachedSession) -> Result<Value, Report> {
    if cached.teams.is_none() { cached.teams = Some(cached.session.list_teams().await?); }
    let team = find_team(request, cached)?;
    let serial = field(request, "serial_number")?;
    cached.session.revoke_development_cert(&team, serial, DeveloperDeviceType::Ios).await.context("撤销证书失败")?;
    // The cached signing identity may be the revoked certificate; fetch it again next time.
    cached.identities.remove(&team.team_id);
    Ok(json!({"ok": true}))
}

#[derive(Clone, Copy)]
enum Operation { Single, App, AppIds, Certificates, Revoke }
async fn with_session(request: Value, vault: Vault, operation: Operation) -> Result<Value, Report> {
    let slot = session_slot(format!("{}\n{}", field(&request,"email")?, field(&request,"anisette_url")?));
    let mut guard = slot.lock().await;
    let state = vault.snapshot();
    let reusable = guard.as_ref().is_some_and(|c| c.created.elapsed() < SESSION_TTL && c.returned_state == state);
    if !reusable { *guard = None; }
    let mut attempt_reused = guard.is_some();
    loop {
        if guard.is_none() { *guard = Some(open_session(&request, vault.clone()).await?); }
        let cached = guard.as_mut().expect("session prepared");
        let result = match operation {
            Operation::Single => profile_in(&request, cached).await,
            Operation::App => app_profiles_in(&request, cached).await,
            Operation::AppIds => app_ids_in(&request, cached).await,
            Operation::Certificates => certificates_in(&request, cached).await,
            Operation::Revoke => revoke_in(&request, cached).await,
        };
        // Changes such as Anisette provisioning or a new private key live in the
        // session's vault; hand them back so the caller persists them.
        vault.replace(cached.vault.snapshot());
        match result {
            Ok(mut value) => {
                cached.returned_state = vault.snapshot();
                value["state"] = vault.json();
                value["session_reused"] = json!(attempt_reused);
                return Ok(value);
            }
            Err(error) => {
                *guard = None;
                // Cached data may be stale (revoked certificate, removed App ID):
                // retry once from a fresh session before reporting the failure.
                if !attempt_reused || matches!(operation, Operation::Revoke) { return Err(error); }
                attempt_reused = false;
            }
        }
    }
}
fn respond(operation: impl FnOnce() -> Result<Value, Report> + std::panic::UnwindSafe) -> *mut c_char {
    let result = match std::panic::catch_unwind(operation) {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => json!({"ok":false,"error":format!("{error:#}")}),
        Err(_) => json!({"ok":false,"error":"Apple signing engine stopped unexpectedly"}),
    };
    CString::new(result.to_string()).unwrap_or_default().into_raw()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_apple_check_service(request: *const c_char) -> *mut c_char {
    if request.is_null() { return std::ptr::null_mut(); }
    let text = unsafe { CStr::from_ptr(request) }.to_string_lossy().into_owned();
    respond(|| {
        let request = serde_json::from_str(&text)?;
        let vault = Vault::from_request(&request)?;
        let account = runtime().block_on(make_account(&request, vault))?;
        Ok(json!({"ok":true, "client_info": account.grandslam_client.client_info.client_info,
                  "user_agent": account.grandslam_client.client_info.user_agent}))
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_apple_login(request: *const c_char, callback: Option<TwoFactor>, context: *mut c_void) -> *mut c_char {
    if request.is_null() { return std::ptr::null_mut(); }
    let text = unsafe { CStr::from_ptr(request) }.to_string_lossy().into_owned();
    let context = context as usize;
    respond(|| {
        let request = serde_json::from_str(&text)?;
        let vault = Vault::from_request(&request)?;
        Ok(match runtime().block_on(login(request,vault.clone(),callback,context)) {
            Ok(value) => value,
            Err(error) => json!({"ok":false,"error":format!("{error:#}"),"state":vault.json()}),
        })
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_apple_profile(request: *const c_char) -> *mut c_char {
    if request.is_null() { return std::ptr::null_mut(); }
    let text = unsafe { CStr::from_ptr(request) }.to_string_lossy().into_owned();
    respond(|| {
        let request = serde_json::from_str(&text)?;
        let vault = Vault::from_request(&request)?;
        Ok(match runtime().block_on(with_session(request,vault.clone(),Operation::Single)) {
            Ok(value) => value,
            Err(error) => json!({"ok":false,"error":format!("{error:#}"),"state":vault.json()}),
        })
    })
}
fn session_call(request: *const c_char, operation: Operation) -> *mut c_char {
    if request.is_null() { return std::ptr::null_mut(); }
    let text = unsafe { CStr::from_ptr(request) }.to_string_lossy().into_owned();
    respond(move || {
        let request = serde_json::from_str(&text)?;
        let vault = Vault::from_request(&request)?;
        Ok(match runtime().block_on(with_session(request,vault.clone(),operation)) {
            Ok(value) => value,
            Err(error) => json!({"ok":false,"error":format!("{error:#}"),"state":vault.json()}),
        })
    })
}
/// The team's iOS development certificates; see `certificates_in`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_apple_certificates(request: *const c_char) -> *mut c_char { session_call(request, Operation::Certificates) }
/// Revokes a development certificate by serial number; see `revoke_in`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_apple_revoke_certificate(request: *const c_char) -> *mut c_char { session_call(request, Operation::Revoke) }
/// The team's App IDs with expiry and remaining quota; see `app_ids_in`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_apple_app_ids(request: *const c_char) -> *mut c_char {
    if request.is_null() { return std::ptr::null_mut(); }
    let text = unsafe { CStr::from_ptr(request) }.to_string_lossy().into_owned();
    respond(|| {
        let request = serde_json::from_str(&text)?;
        let vault = Vault::from_request(&request)?;
        Ok(match runtime().block_on(with_session(request,vault.clone(),Operation::AppIds)) {
            Ok(value) => value,
            Err(error) => json!({"ok":false,"error":format!("{error:#}"),"state":vault.json()}),
        })
    })
}
/// Profiles for an app and its extensions (SideStore flow); see `app_profiles_in`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_apple_app_profiles(request: *const c_char) -> *mut c_char {
    if request.is_null() { return std::ptr::null_mut(); }
    let text = unsafe { CStr::from_ptr(request) }.to_string_lossy().into_owned();
    respond(|| {
        let request = serde_json::from_str(&text)?;
        let vault = Vault::from_request(&request)?;
        Ok(match runtime().block_on(with_session(request,vault.clone(),Operation::App)) {
            Ok(value) => value,
            Err(error) => json!({"ok":false,"error":format!("{error:#}"),"state":vault.json()}),
        })
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_apple_string_free(value: *mut c_char) {
    if !value.is_null() { drop(unsafe { CString::from_raw(value) }); }
}
