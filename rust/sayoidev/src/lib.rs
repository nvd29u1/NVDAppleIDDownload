//! C API used by the SayoSign iOS app (see ../sayoidev.h).
//!
//! * `sayo_idev_pair_host`: iOS 27 device-initiated pairing. SayoSign listens on a TCP port and
//!   the app advertises `_remotepairing-pairable-host._tcp` with the system Bonjour API (no
//!   multicast entitlement needed); the user taps "Pair with SayoSign" in Settings → Developer
//!   Mode and types the PIN. The resulting RPPairing file is written to `out_path`.
//! * `sayo_idev_install`: opens the RPPairing tunnel to this iPhone through LocalDevVPN, uploads
//!   the IPA over AFC and installs it with installation_proxy, as SideStore does. This works for
//!   free Apple ID profiles, which over-the-air installs refuse.
//!
//! The tunnel code mirrors idevice's own FFI (`ffi/src/tunnel_provider.rs`).

use std::ffi::{CStr, CString, c_char, c_void};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use idevice::IdeviceError;
use idevice::remote_pairing::{
    PairableHost, PairableHostInfo, RemotePairingClient, RpPairingFile, RpPairingSocket,
    connect_tls_psk_tunnel_native,
};
use idevice::rsd::RsdHandshake;
use once_cell::sync::Lazy;
use tokio::runtime::Runtime;
use tokio::sync::Semaphore;

static RT: Lazy<Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("tokio runtime")
});

pub type ReadyCb = Option<extern "C" fn(port: u16, json: *const c_char, ctx: *mut c_void)>;
pub type PinCb = Option<extern "C" fn(pin: *const c_char, ctx: *mut c_void)>;
pub type ProgressCb = Option<extern "C" fn(percent: u64, stage: *const c_char, ctx: *mut c_void)>;

#[derive(Clone, Copy)]
struct Ctx(*mut c_void);
unsafe impl Send for Ctx {}
unsafe impl Sync for Ctx {}

/// Cancellation token: a zero-permit semaphore, closed to cancel.
pub struct SayoCancel(Arc<Semaphore>);

#[unsafe(no_mangle)]
pub extern "C" fn sayo_idev_cancel_new() -> *mut SayoCancel {
    Box::into_raw(Box::new(SayoCancel(Arc::new(Semaphore::new(0)))))
}

/// # Safety
/// `c` must come from `sayo_idev_cancel_new` and not be freed yet (or be NULL).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sayo_idev_cancel_signal(c: *const SayoCancel) {
    if let Some(c) = unsafe { c.as_ref() } {
        c.0.close();
    }
}

/// # Safety
/// `c` must come from `sayo_idev_cancel_new` (or be NULL) and not be used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sayo_idev_cancel_free(c: *mut SayoCancel) {
    if !c.is_null() {
        drop(unsafe { Box::from_raw(c) });
    }
}

fn cstr(p: *const c_char) -> Result<String, String> {
    if p.is_null() {
        return Err("missing argument".into());
    }
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .map(str::to_owned)
        .map_err(|_| "invalid string".into())
}

fn write_out(buf: *mut c_char, len: usize, msg: &str) {
    if buf.is_null() || len == 0 {
        return;
    }
    let bytes = msg.as_bytes();
    let n = bytes.len().min(len - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, n);
        *buf.add(n) = 0;
    }
}

fn describe(e: IdeviceError) -> String {
    format!("{e}")
}

/// Waits for this iPhone to pair with SayoSign (iOS 27+).
///
/// # Safety
/// Strings must be valid NUL-terminated UTF-8 (`model` may be NULL); `err` must point to
/// `err_len` writable bytes; `cancel` must be NULL or a live token.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn sayo_idev_pair_host(
    name: *const c_char,
    model: *const c_char,
    out_path: *const c_char,
    ready: ReadyCb,
    pin: PinCb,
    ctx: *mut c_void,
    cancel: *const SayoCancel,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    let (name, out_path) = match (cstr(name), cstr(out_path)) {
        (Ok(a), Ok(b)) => (a, b),
        _ => {
            write_out(err, err_len, "invalid arguments");
            return -1;
        }
    };
    let model = cstr(model).unwrap_or_else(|_| "Mac17,7".into());
    let ctx = Ctx(ctx);
    let cancel = unsafe { cancel.as_ref() }.map(|c| c.0.clone());

    let res: Result<(), String> = RT.block_on(async move {
        // Settings connects to the advertised addresses, usually over IPv6 (link-local), so
        // listen on both IPv6 and IPv4 with the same port (like PhonePair's dual-stack listener).
        let v6 = tokio::net::TcpListener::bind((Ipv6Addr::UNSPECIFIED, 0)).await.ok();
        let port0 = v6.as_ref().and_then(|l| l.local_addr().ok()).map(|a| a.port()).unwrap_or(0);
        let v4 = tokio::net::TcpListener::bind((Ipv4Addr::UNSPECIFIED, port0)).await.ok();
        if v6.is_none() && v4.is_none() {
            return Err("bind: no IPv4 or IPv6 listener".to_string());
        }
        let port = v6
            .as_ref()
            .or(v4.as_ref())
            .and_then(|l| l.local_addr().ok())
            .map(|a| a.port())
            .ok_or_else(|| "bind: no port".to_string())?;
        let mut pairing_file = RpPairingFile::generate(&name);
        let host_info = PairableHostInfo::generate(&name, &model);
        let service = pairing_file.identifier.clone();
        let txt: serde_json::Map<String, serde_json::Value> = host_info
            .mdns_txt_records(&service)
            .into_iter()
            .map(|(k, v)| (k, serde_json::Value::String(v)))
            .collect();
        let json = serde_json::json!({ "name": service, "txt": txt }).to_string();
        if let (Some(cb), Ok(c)) = (ready, CString::new(json)) {
            cb(port, c.as_ptr(), ctx.0);
        }
        let pair = async {
            let accept_v6 = async {
                match &v6 {
                    Some(l) => l.accept().await,
                    None => std::future::pending().await,
                }
            };
            let accept_v4 = async {
                match &v4 {
                    Some(l) => l.accept().await,
                    None => std::future::pending().await,
                }
            };
            let (stream, _) = tokio::select! {
                r = accept_v6 => r,
                r = accept_v4 => r,
            }
            .map_err(|e| format!("accept: {e}"))?;
            let mut host = PairableHost::new(RpPairingSocket::new_device(stream), host_info);
            host.accept(&mut pairing_file, |p: String| async move {
                if let (Some(cb), Ok(c)) = (pin, CString::new(p)) {
                    cb(c.as_ptr(), ctx.0);
                }
            })
            .await
            .map_err(describe)?;
            Ok::<(), String>(())
        };
        match cancel {
            Some(c) => {
                tokio::select! {
                    biased;
                    _ = c.acquire() => return Err("cancelled".to_string()),
                    r = pair => r?,
                }
            }
            None => pair.await?,
        }
        pairing_file
            .write_to_file(&out_path)
            .await
            .map_err(describe)?;
        Ok(())
    });
    match res {
        Ok(()) => 0,
        Err(e) if e == "cancelled" => -2,
        Err(e) => {
            write_out(err, err_len, &e);
            -1
        }
    }
}

async fn open_tunnel(
    pairing_path: &str,
    addr: SocketAddr,
) -> Result<(idevice::tcp::handle::AdapterHandle, RsdHandshake), String> {
    let mut rpf = RpPairingFile::read_from_file(pairing_path)
        .await
        .map_err(describe)?;
    let stream = tokio::time::timeout(Duration::from_secs(8), tokio::net::TcpStream::connect(addr))
        .await
        .map_err(|_| format!("cannot reach {addr}: is LocalDevVPN connected?"))?
        .map_err(|e| format!("cannot reach {addr} ({e}): is LocalDevVPN connected?"))?;
    let mut rpc = RemotePairingClient::new(RpPairingSocket::new(stream), "SayoSign");
    // A valid pairing only needs pair-verify; the PIN would only be asked for a new pair-setup,
    // which the device does not allow from here, so an invalid pairing just fails.
    rpc.connect(&mut rpf, || async { String::from("000000") })
        .await
        .map_err(|e| format!("the iPhone rejected the pairing ({e}); pair again in NVDAppleIDDownload"))?;
    let tunnel_port = rpc.create_tcp_listener().await.map_err(describe)?;
    let mut taddr = addr;
    taddr.set_port(tunnel_port);
    let ts = tokio::time::timeout(Duration::from_secs(8), tokio::net::TcpStream::connect(taddr))
        .await
        .map_err(|_| "tunnel: timeout".to_string())?
        .map_err(|e| format!("tunnel: {e}"))?;
    let tunnel = connect_tls_psk_tunnel_native(ts, rpc.encryption_key())
        .await
        .map_err(describe)?;
    let client_ip: IpAddr = tunnel
        .info
        .client_address
        .parse()
        .map_err(|e| format!("{e}"))?;
    let server_ip: IpAddr = tunnel
        .info
        .server_address
        .parse()
        .map_err(|e| format!("{e}"))?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;
    let raw = tunnel.into_inner();
    let mut adapter = idevice::tcp::adapter::Adapter::new(Box::new(raw), client_ip, server_ip);
    adapter.set_mss(mtu.saturating_sub(60));
    let mut adapter = adapter.to_async_handle();
    let rsd = adapter
        .connect(rsd_port)
        .await
        .map_err(|e| format!("rsd: {e}"))?;
    let handshake = RsdHandshake::new(rsd).await.map_err(describe)?;
    Ok((adapter, handshake))
}

fn sockaddr(addr: &str, port: u16) -> Result<SocketAddr, String> {
    let ip: IpAddr = addr.parse().map_err(|_| format!("bad address {addr}"))?;
    Ok(SocketAddr::new(ip, port))
}

/// Checks that the tunnel opens; writes a short status into `out`. 0 on success.
///
/// # Safety
/// Strings must be valid NUL-terminated UTF-8; `out`/`err` must point to that many bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sayo_idev_check(
    pairing_path: *const c_char,
    addr: *const c_char,
    port: u16,
    out: *mut c_char,
    out_len: usize,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    let res: Result<String, String> = (|| {
        let path = cstr(pairing_path)?;
        let sa = sockaddr(&cstr(addr)?, port)?;
        RT.block_on(async move {
            let (_adapter, hs) = open_tunnel(&path, sa).await?;
            Ok(format!("connected, {} services", hs.services.len()))
        })
    })();
    match res {
        Ok(s) => {
            write_out(out, out_len, &s);
            0
        }
        Err(e) => {
            write_out(err, err_len, &e);
            -1
        }
    }
}

/// Installs (or upgrades) `ipa_path` on this iPhone through the RPPairing tunnel.
///
/// # Safety
/// Strings must be valid NUL-terminated UTF-8; `err` must point to `err_len` writable bytes.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn sayo_idev_install(
    pairing_path: *const c_char,
    addr: *const c_char,
    port: u16,
    ipa_path: *const c_char,
    progress: ProgressCb,
    ctx: *mut c_void,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    let ctx = Ctx(ctx);
    let report = move |p: u64, s: &str| {
        if let (Some(cb), Ok(c)) = (progress, CString::new(s)) {
            cb(p, c.as_ptr(), ctx.0);
        }
    };
    let res: Result<(), String> = (|| {
        let path = cstr(pairing_path)?;
        let ipa = cstr(ipa_path)?;
        let sa = sockaddr(&cstr(addr)?, port)?;
        RT.block_on(async move {
            report(0, "tunnel");
            let (mut adapter, mut hs) = open_tunnel(&path, sa).await?;
            report(0, "upload");
            idevice::utils::installation::install_package_with_callback_rsd(
                &mut adapter,
                &mut hs,
                &ipa,
                None,
                move |(p, _): (u64, ())| async move { report(p, "install") },
                (),
            )
            .await
            .map_err(describe)?;
            report(100, "done");
            Ok(())
        })
    })();
    match res {
        Ok(()) => 0,
        Err(e) => {
            write_out(err, err_len, &e);
            -1
        }
    }
}
