#[cfg(not(target_os = "ios"))]
use camellia_remote_protocol::whoami;
use camellia_remote_protocol::{
    allow_err,
    anyhow::bail,
    config::Config,
    config::{self, RENDEZVOUS_PORT},
    log,
    protobuf::Message as _,
    rendezvous_proto::*,
    tokio::{
        self,
        sync::mpsc::{channel, Receiver, Sender},
    },
    ResultType,
};

use std::{
    collections::HashMap,
    net::{IpAddr, Ipv4Addr, SocketAddr, ToSocketAddrs, UdpSocket},
    sync::Arc,
    time::Instant,
};

type Message = RendezvousMessage;

// RES-035: LAN Discovery Lifecycle and Resource Bounds
pub const DISCOVERY_DEADLINE: std::time::Duration = std::time::Duration::from_millis(3000);
pub const MAX_DISCOVERY_PACKETS: usize = 512;
pub const MAX_DISCOVERED_PEERS: usize = 128;
pub const DISCOVERY_CHANNEL_CAPACITY: usize = 64;
pub const MAX_PEER_ID_LEN: usize = 32;
pub const MAX_MAC_LEN: usize = 64;
pub const MAX_HOSTNAME_LEN: usize = 64;
pub const MAX_USERNAME_LEN: usize = 64;
pub const MAX_PLATFORM_LEN: usize = 32;

lazy_static::lazy_static! {
    static ref DISCOVERY_MANAGER: std::sync::Mutex<Option<Arc<(std::sync::Mutex<bool>, std::sync::Condvar)>>> =
        std::sync::Mutex::new(None);
}

pub fn is_discovering() -> bool {
    DISCOVERY_MANAGER.lock().unwrap().is_some()
}

/// Clamps a string to at most `max_bytes` without panicking on multi-byte UTF-8 char boundaries.
#[inline]
pub fn clamp_utf8(s: &mut String, max_bytes: usize) {
    if s.len() > max_bytes {
        let mut idx = max_bytes;
        while idx > 0 && !s.is_char_boundary(idx) {
            idx -= 1;
        }
        s.truncate(idx);
    }
}

#[cfg(not(target_os = "ios"))]
pub(super) fn start_listening() -> ResultType<()> {
    let addr = SocketAddr::from(([0, 0, 0, 0], get_broadcast_port()));
    let socket = std::net::UdpSocket::bind(addr)?;
    socket.set_read_timeout(Some(std::time::Duration::from_millis(1000)))?;
    log::info!("lan discovery listener started");
    while crate::common::is_server_running() {
        let mut buf = [0; 2048];
        if let Ok((len, addr)) = socket.recv_from(&mut buf) {
            if let Ok(msg_in) = Message::parse_from_bytes(&buf[0..len]) {
                match msg_in.union {
                    Some(rendezvous_message::Union::PeerDiscovery(p)) => {
                        if p.cmd == "ping"
                            && config::option2bool(
                                "enable-lan-discovery",
                                &Config::get_option("enable-lan-discovery"),
                            )
                        {
                            let id = Config::get_id();
                            if p.id == id {
                                continue;
                            }
                            if let Some(self_addr) = get_ipaddr_by_peer(&addr) {
                                let mut msg_out = Message::new();
                                let mut hostname = crate::whoami_hostname();
                                // The default hostname is "localhost" which is a bit confusing
                                if hostname == "localhost" {
                                    hostname = "unknown".to_owned();
                                }
                                let peer = PeerDiscovery {
                                    cmd: "pong".to_owned(),
                                    mac: get_mac(&self_addr),
                                    id,
                                    hostname,
                                    username: crate::platform::get_active_username(),
                                    platform: whoami::platform().to_string(),
                                    ..Default::default()
                                };
                                msg_out.set_peer_discovery(peer);
                                socket.send_to(&msg_out.write_to_bytes()?, addr).ok();
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
    }
    log::info!("lan discovery listener stopped");
    Ok(())
}

pub fn discover() -> ResultType<()> {
    let (waiter, is_leader) = {
        let mut mgr = DISCOVERY_MANAGER.lock().unwrap();
        if let Some(ref coordinator) = *mgr {
            (coordinator.clone(), false)
        } else {
            let coordinator = Arc::new((std::sync::Mutex::new(false), std::sync::Condvar::new()));
            *mgr = Some(coordinator.clone());
            (coordinator, true)
        }
    };

    if !is_leader {
        log::info!("LAN discovery already in progress, awaiting existing execution");
        let (lock, cvar) = &*waiter;
        let mut completed = lock.lock().unwrap();
        while !*completed {
            completed = cvar.wait(completed).unwrap();
        }
        return Ok(());
    }

    struct DiscoveryGuard;
    impl Drop for DiscoveryGuard {
        fn drop(&mut self) {
            let coordinator = {
                let mut mgr = DISCOVERY_MANAGER.lock().unwrap();
                mgr.take()
            };
            if let Some(coord) = coordinator {
                let (lock, cvar) = &*coord;
                let mut completed = lock.lock().unwrap();
                *completed = true;
                cvar.notify_all();
            }
        }
    }
    let _guard = DiscoveryGuard;

    discover_impl()
}

#[tokio::main(flavor = "current_thread")]
async fn discover_impl() -> ResultType<()> {
    let sockets = send_query()?;
    let deadline = Instant::now() + DISCOVERY_DEADLINE;
    let (rx, worker_handles) = spawn_wait_responses(sockets, deadline);

    // Drain and process responses directly on current thread to prevent bounded channel deadlock
    handle_received_peers(rx).await?;

    for handle in worker_handles {
        let _ = handle.join();
    }

    log::info!("discover ping done");
    Ok(())
}

pub fn send_wol(id: String) {
    #[cfg(not(target_os = "ios"))]
    {
        let interfaces = default_net::get_interfaces();
        for peer in &config::LanPeers::load().peers {
            if peer.id == id {
                for (_, mac) in peer.ip_mac.iter() {
                    if let Ok(mac_addr) = mac.parse() {
                        for interface in &interfaces {
                            for ipv4 in &interface.ipv4 {
                                // remove below mask check to avoid unexpected bug
                                // if (u32::from(ipv4.addr) & u32::from(ipv4.netmask)) == (u32::from(peer_ip) & u32::from(ipv4.netmask))
                                log::info!("Send wol to {mac_addr} of {}", ipv4.addr);
                                allow_err!(wol::send_wol(
                                    mac_addr,
                                    None,
                                    Some(IpAddr::V4(ipv4.addr))
                                ));
                            }
                        }
                    }
                }
                break;
            }
        }
    }
    #[cfg(target_os = "ios")]
    {
        let _ = id;
    }
}

#[inline]
fn get_broadcast_port() -> u16 {
    (RENDEZVOUS_PORT + 3) as _
}

fn get_mac(_ip: &IpAddr) -> String {
    #[cfg(not(target_os = "ios"))]
    if let Ok(mac) = get_mac_by_ip(_ip) {
        mac.to_string()
    } else {
        "".to_owned()
    }
    #[cfg(target_os = "ios")]
    "".to_owned()
}

#[cfg(not(target_os = "ios"))]
fn get_mac_by_ip(ip: &IpAddr) -> ResultType<String> {
    for interface in default_net::get_interfaces() {
        match ip {
            IpAddr::V4(local_ipv4) => {
                if interface.ipv4.iter().any(|x| x.addr == *local_ipv4) {
                    if let Some(mac_addr) = interface.mac_addr {
                        return Ok(mac_addr.address());
                    }
                }
            }
            IpAddr::V6(local_ipv6) => {
                if interface.ipv6.iter().any(|x| x.addr == *local_ipv6) {
                    if let Some(mac_addr) = interface.mac_addr {
                        return Ok(mac_addr.address());
                    }
                }
            }
        }
    }
    bail!("No interface found for ip: {:?}", ip);
}

// Mainly from https://github.com/shellrow/default-net/blob/cf7ca24e7e6e8e566ed32346c9cfddab3f47e2d6/src/interface/shared.rs#L4
fn get_ipaddr_by_peer<A: ToSocketAddrs>(peer: A) -> Option<IpAddr> {
    let socket = match UdpSocket::bind("0.0.0.0:0") {
        Ok(s) => s,
        Err(_) => return None,
    };

    match socket.connect(peer) {
        Ok(()) => (),
        Err(_) => return None,
    };

    match socket.local_addr() {
        Ok(addr) => return Some(addr.ip()),
        Err(_) => return None,
    };
}

fn create_broadcast_sockets() -> Vec<UdpSocket> {
    let mut ipv4s = Vec::new();
    // TODO: maybe we should use a better way to get ipv4 addresses.
    // But currently, it's ok to use `[Ipv4Addr::UNSPECIFIED]` for discovery.
    // `default_net::get_interfaces()` causes undefined symbols error when `flutter build` on iOS simulator x86_64
    #[cfg(not(any(target_os = "ios")))]
    for interface in default_net::get_interfaces() {
        for ipv4 in &interface.ipv4 {
            ipv4s.push(ipv4.addr.clone());
        }
    }
    ipv4s.push(Ipv4Addr::UNSPECIFIED); // for robustness
    let mut sockets = Vec::new();
    for v4_addr in ipv4s {
        // removing v4_addr.is_private() check, https://github.com/rustdesk/rustdesk/issues/4663
        if let Ok(s) = UdpSocket::bind(SocketAddr::from((v4_addr, 0))) {
            if s.set_broadcast(true).is_ok() {
                sockets.push(s);
            }
        }
    }
    sockets
}

fn send_query() -> ResultType<Vec<UdpSocket>> {
    let sockets = create_broadcast_sockets();
    if sockets.is_empty() {
        bail!("Found no bindable ipv4 addresses");
    }

    let mut msg_out = Message::new();
    // We may not be able to get the mac address on mobile platforms.
    // So we need to use the id to avoid discovering ourselves.
    #[cfg(any(target_os = "android", target_os = "ios"))]
    let id = crate::ui_interface::get_id();
    // `crate::ui_interface::get_id()` will cause error:
    // `get_id()` uses async code with `current_thread`, which is not allowed in this context.
    //
    // No need to get id for desktop platforms.
    // We can use the mac address to identify the device.
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    let id = "".to_owned();
    let peer = PeerDiscovery {
        cmd: "ping".to_owned(),
        id,
        ..Default::default()
    };
    msg_out.set_peer_discovery(peer);
    let out = msg_out.write_to_bytes()?;
    let maddr = SocketAddr::from(([255, 255, 255, 255], get_broadcast_port()));
    for socket in &sockets {
        allow_err!(socket.send_to(&out, maddr));
    }
    log::info!("discover ping sent");
    Ok(sockets)
}

fn wait_response(
    socket: UdpSocket,
    deadline: Instant,
    tx: Sender<config::DiscoveryPeer>,
) -> ResultType<()> {
    let local_addr = socket.local_addr();
    let try_get_ip_by_peer = match local_addr.as_ref() {
        Err(..) => true,
        Ok(addr) => addr.ip().is_unspecified(),
    };
    let mut mac: Option<String> = None;
    let mut packet_count: usize = 0;

    loop {
        let now = Instant::now();
        if now >= deadline {
            break;
        }
        let remaining = deadline.saturating_duration_since(now);
        let read_timeout = std::cmp::min(remaining, std::time::Duration::from_millis(10));
        socket.set_read_timeout(Some(read_timeout))?;

        let mut buf = [0; 2048];
        if let Ok((len, addr)) = socket.recv_from(&mut buf) {
            packet_count += 1;
            if packet_count > MAX_DISCOVERY_PACKETS {
                log::warn!(
                    "Reached MAX_DISCOVERY_PACKETS ({}), stopping wait_response for socket",
                    MAX_DISCOVERY_PACKETS
                );
                break;
            }

            if let Ok(msg_in) = Message::parse_from_bytes(&buf[0..len]) {
                match msg_in.union {
                    Some(rendezvous_message::Union::PeerDiscovery(p)) => {
                        if p.cmd == "pong" {
                            if !crate::common::is_valid_untrusted_peer_id(&p.id)
                                || p.id.len() > MAX_PEER_ID_LEN
                            {
                                log::warn!(
                                    "Ignoring LAN discovery response from {} with invalid or oversized peer id",
                                    addr
                                );
                                continue;
                            }

                            let mut peer_mac = p.mac;
                            clamp_utf8(&mut peer_mac, MAX_MAC_LEN);
                            let mut hostname = p.hostname;
                            clamp_utf8(&mut hostname, MAX_HOSTNAME_LEN);
                            let mut username = p.username;
                            clamp_utf8(&mut username, MAX_USERNAME_LEN);
                            let mut platform = p.platform;
                            clamp_utf8(&mut platform, MAX_PLATFORM_LEN);

                            let local_mac = if try_get_ip_by_peer {
                                if let Some(self_addr) = get_ipaddr_by_peer(&addr) {
                                    get_mac(&self_addr)
                                } else {
                                    "".to_owned()
                                }
                            } else {
                                match mac.as_ref() {
                                    Some(m) => m.clone(),
                                    None => {
                                        let m = if let Ok(local_addr) = local_addr {
                                            get_mac(&local_addr.ip())
                                        } else {
                                            "".to_owned()
                                        };
                                        mac = Some(m.clone());
                                        m
                                    }
                                }
                            };

                            if (local_mac.is_empty() && peer_mac.is_empty())
                                || local_mac != peer_mac
                            {
                                let discovery_peer = config::DiscoveryPeer {
                                    id: p.id,
                                    ip_mac: HashMap::from([(addr.ip().to_string(), peer_mac)]),
                                    username,
                                    hostname,
                                    platform,
                                    online: true,
                                };
                                let _ = tx.blocking_send(discovery_peer);
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
    }
    Ok(())
}

fn spawn_wait_responses(
    sockets: Vec<UdpSocket>,
    deadline: Instant,
) -> (
    Receiver<config::DiscoveryPeer>,
    Vec<std::thread::JoinHandle<()>>,
) {
    let (tx, rx) = channel::<config::DiscoveryPeer>(DISCOVERY_CHANNEL_CAPACITY);
    let mut handles = Vec::with_capacity(sockets.len());
    for socket in sockets {
        let tx_clone = tx.clone();
        let handle = std::thread::spawn(move || {
            allow_err!(wait_response(socket, deadline, tx_clone));
        });
        handles.push(handle);
    }
    drop(tx);
    (rx, handles)
}

async fn handle_received_peers(mut rx: Receiver<config::DiscoveryPeer>) -> ResultType<()> {
    let mut peer_map: HashMap<String, config::DiscoveryPeer> =
        HashMap::with_capacity(MAX_DISCOVERED_PEERS);

    for mut peer in config::LanPeers::load().peers {
        peer.online = false;
        peer_map.insert(peer.id.clone(), peer);
    }

    while let Some(peer) = rx.recv().await {
        if peer_map.len() >= MAX_DISCOVERED_PEERS && !peer_map.contains_key(&peer.id) {
            // Evict an offline peer first to allow newly discovered online peers
            if let Some(offline_id) =
                peer_map
                    .iter()
                    .find_map(|(id, p)| if !p.online { Some(id.clone()) } else { None })
            {
                peer_map.remove(&offline_id);
            } else {
                log::warn!(
                    "Reached MAX_DISCOVERED_PEERS ({}) with all peers online, dropping extra peer {}",
                    MAX_DISCOVERED_PEERS,
                    peer.id
                );
                continue;
            }
        }

        match peer_map.get_mut(&peer.id) {
            Some(existing) => {
                existing.ip_mac.extend(peer.ip_mac);
                existing.online = true;
                if !peer.username.is_empty() {
                    existing.username = peer.username;
                }
                if !peer.hostname.is_empty() {
                    existing.hostname = peer.hostname;
                }
                if !peer.platform.is_empty() {
                    existing.platform = peer.platform;
                }
            }
            None => {
                peer_map.insert(peer.id.clone(), peer);
            }
        }
    }

    let mut peers: Vec<config::DiscoveryPeer> = peer_map.into_values().collect();
    peers.sort_by(|a, b| b.online.cmp(&a.online));
    config::LanPeers::store(&peers);
    #[cfg(feature = "flutter")]
    crate::flutter_ffi::main_load_lan_peers();
    Ok(())
}
