use std::sync::{Arc, RwLock};
use std::time::Duration;

use crate::client::*;
use camellia_remote_protocol::{
    allow_err, bail,
    futures::{SinkExt, StreamExt},
    log,
    message_proto::*,
    protobuf::Message as _,
    rendezvous_proto::ConnType,
    tcp,
    tokio::{self, net::TcpStream, sync::mpsc},
    tokio_util::{
        codec::{BytesCodec, Framed},
        sync::CancellationToken,
    },
    ResultType, Stream,
};

pub const MAX_ACTIVE_TUNNELS_PER_LISTENER: usize = 32;
pub const MAX_GLOBAL_ACTIVE_TUNNELS: usize = 128;
pub const MAX_PRELOGIN_BUFFER_BYTES: usize = 64 * 1024; // 64 KiB
pub const PRELOGIN_DEADLINE: Duration = Duration::from_secs(30);

lazy_static::lazy_static! {
    static ref GLOBAL_TUNNEL_SEMAPHORE: Arc<tokio::sync::Semaphore> =
        Arc::new(tokio::sync::Semaphore::new(MAX_GLOBAL_ACTIVE_TUNNELS));
}

pub fn get_global_available_permits() -> usize {
    GLOBAL_TUNNEL_SEMAPHORE.available_permits()
}

fn run_rdp(port: u16) {
    std::process::Command::new("cmdkey")
        .arg("/delete:localhost")
        .output()
        .ok();
    let username = std::env::var("rdp_username").unwrap_or_default();
    let password = std::env::var("rdp_password").unwrap_or_default();
    if !username.is_empty() || !password.is_empty() {
        let mut args = vec!["/generic:localhost".to_owned()];
        if !username.is_empty() {
            args.push(format!("/user:{}", username));
        }
        if !password.is_empty() {
            args.push(format!("/pass:{}", password));
        }
        std::process::Command::new("cmdkey")
            .args(&args)
            .output()
            .ok();
    }
    std::process::Command::new("mstsc")
        .arg(format!("/v:localhost:{}", port))
        .spawn()
        .ok();
}

pub async fn listen(
    id: String,
    password: String,
    port: i32,
    interface: impl Interface,
    ui_receiver: mpsc::UnboundedReceiver<Data>,
    key: &str,
    token: &str,
    lc: Arc<RwLock<LoginConfigHandler>>,
    remote_host: String,
    remote_port: i32,
) -> ResultType<()> {
    let listener = tcp::new_listener(format!("127.0.0.1:{}", port), true).await?;
    let addr = listener.local_addr()?;
    log::info!("listening on port {:?}", addr);
    let is_rdp = port == 0;
    if is_rdp {
        run_rdp(addr.port());
    }
    let mut ui_receiver = ui_receiver;
    let listener_semaphore = Arc::new(tokio::sync::Semaphore::new(MAX_ACTIVE_TUNNELS_PER_LISTENER));
    let cancel_token = CancellationToken::new();

    loop {
        tokio::select! {
            accept_res = listener.accept() => {
                match accept_res {
                    Ok((forward, addr)) => {
                        log::info!("new connection from {:?}", addr);

                        // Bound active tunnel capacity per listener and globally (RES-024)
                        let global_permit = match GLOBAL_TUNNEL_SEMAPHORE.clone().try_acquire_owned() {
                            Ok(p) => p,
                            Err(_) => {
                                log::warn!(
                                    "Global port forward capacity reached ({} tunnels), dropping connection from {:?}",
                                    MAX_GLOBAL_ACTIVE_TUNNELS,
                                    addr
                                );
                                continue;
                            }
                        };
                        let listener_permit = match listener_semaphore.clone().try_acquire_owned() {
                            Ok(p) => p,
                            Err(_) => {
                                log::warn!(
                                    "Listener port forward capacity reached ({} tunnels), dropping connection from {:?}",
                                    MAX_ACTIVE_TUNNELS_PER_LISTENER,
                                    addr
                                );
                                continue;
                            }
                        };

                        lc.write().unwrap().port_forward = (remote_host.clone(), remote_port);
                        let id = id.clone();
                        let password = password.clone();
                        let mut forward = Framed::new(forward, BytesCodec::new());
                        let mut close_port_forward = false;
                        let tunnel_cancel = cancel_token.child_token();

                        match connect_and_login(
                            &id,
                            &password,
                            &mut ui_receiver,
                            interface.clone(),
                            &mut forward,
                            key,
                            token,
                            is_rdp,
                            &mut close_port_forward,
                            &tunnel_cancel,
                        ).await {
                            Ok(Some(stream)) => {
                                let interface = interface.clone();
                                tokio::spawn(async move {
                                    let _gp = global_permit;
                                    let _lp = listener_permit;
                                    tokio::select! {
                                        _ = tunnel_cancel.cancelled() => {
                                            log::info!("tunnel from {:?} cancelled by listener teardown", addr);
                                        }
                                        res = run_forward(forward, stream) => {
                                            if let Err(err) = res {
                                                interface.msgbox("error", "Error", &err.to_string(), "");
                                            }
                                        }
                                    }
                                    log::info!("connection from {:?} closed", addr);
                                });
                            }
                            _ if close_port_forward => {
                                break;
                            }
                            Err(err) => {
                                interface.on_establish_connection_error(err.to_string());
                            }
                            _ => {}
                        }
                    }
                    Err(e) => {
                        log::error!("port forward listener accept failed: {:?}", e);
                        break;
                    }
                }
            }
            d = ui_receiver.recv() => {
                match d {
                    Some(Data::Close) | None => {
                        log::info!("port forward listener on {:?} received close or channel EOF", addr);
                        break;
                    }
                    Some(Data::NewRDP) => {
                        log::info!("receive run_rdp from ui_receiver");
                        run_rdp(addr.port());
                    }
                    _ => {}
                }
            }
        }
    }
    cancel_token.cancel();
    Ok(())
}

async fn connect_and_login(
    id: &str,
    password: &str,
    ui_receiver: &mut mpsc::UnboundedReceiver<Data>,
    interface: impl Interface,
    forward: &mut Framed<TcpStream, BytesCodec>,
    key: &str,
    token: &str,
    is_rdp: bool,
    close_port_forward: &mut bool,
    cancel_token: &CancellationToken,
) -> ResultType<Option<Stream>> {
    let conn_type = if is_rdp {
        ConnType::RDP
    } else {
        ConnType::PORT_FORWARD
    };
    let ((mut stream, direct, _pk, _kcp, _stream_type), (feedback, rendezvous_server)) =
        Client::start(id, key, token, conn_type, interface.clone()).await?;
    interface.update_direct(Some(direct));
    if !stream.is_secured() && !crate::common::is_direct_ip_access(id) {
        if !confirm_insecure_connection(&interface, ui_receiver).await {
            *close_port_forward = true;
            return Ok(None);
        }
    }
    let mut buffer = Vec::new();
    let mut received = false;

    let _keep_it = hc_connection(feedback, rendezvous_server, token).await;

    // RES-024: Enforce an immutable absolute deadline for the entire login sequence
    let deadline = tokio::time::Instant::now() + PRELOGIN_DEADLINE;

    loop {
        tokio::select! {
            _ = cancel_token.cancelled() => {
                bail!("Port-forward connection cancelled");
            }
            _ = tokio::time::sleep_until(deadline) => {
                bail!("Port-forward login deadline exceeded (30s)");
            }
            res = stream.next() => match res {
                Some(Ok(bytes)) => {
                    if !received {
                        received = true;
                        interface.update_received(true);
                    }
                    let msg_in = Message::parse_from_bytes(&bytes)?;
                    match msg_in.union {
                        Some(message::Union::Hash(hash)) => {
                            interface.handle_hash(password, hash, &mut stream).await;
                        }
                        Some(message::Union::LoginResponse(lr)) => match lr.union {
                            Some(login_response::Union::Error(err)) => {
                                if !interface.handle_login_error(&err) {
                                    return Ok(None);
                                }
                            }
                            Some(login_response::Union::PeerInfo(pi)) => {
                                interface.handle_peer_info(pi);
                                break;
                            }
                            _ => {}
                        }
                        Some(message::Union::TestDelay(t)) => {
                            interface.handle_test_delay(t, &mut stream).await;
                        }
                        _ => {}
                    }
                }
                Some(Err(err)) => {
                    bail!("Connection closed: {}", err);
                }
                None => {
                    bail!("Reset by the peer");
                }
            },
            d = ui_receiver.recv() => {
                match d {
                    Some(Data::Login((os_username, os_password, password, remember))) => {
                        interface.handle_login_from_ui(os_username, os_password, password, remember, &mut stream).await;
                    }
                    Some(Data::Message(msg)) => {
                        allow_err!(stream.send(&msg).await);
                    }
                    Some(Data::Close) | None => {
                        *close_port_forward = true;
                        return Ok(None);
                    }
                    _ => {}
                }
            },
            res = forward.next(), if buffer.len() < MAX_PRELOGIN_BUFFER_BYTES => {
                if let Some(Ok(bytes)) = res {
                    let to_take = (MAX_PRELOGIN_BUFFER_BYTES - buffer.len()).min(bytes.len());
                    buffer.extend_from_slice(&bytes[..to_take]);
                    if buffer.len() >= MAX_PRELOGIN_BUFFER_BYTES {
                        log::warn!(
                            "Prelogin buffer limit reached ({} bytes), pausing local reads until login succeeds",
                            MAX_PRELOGIN_BUFFER_BYTES
                        );
                    }
                } else {
                    return Ok(None);
                }
            },
        }
    }
    stream.set_raw();
    if !buffer.is_empty() {
        allow_err!(stream.send_bytes(buffer.into()).await);
    }
    Ok(Some(stream))
}

async fn run_forward(forward: Framed<TcpStream, BytesCodec>, stream: Stream) -> ResultType<()> {
    log::info!("new port forwarding connection started");
    let mut forward = forward;
    let mut stream = stream;
    loop {
        tokio::select! {
            res = forward.next() => {
                match res {
                    Some(Ok(bytes)) => {
                        if let Err(e) = stream.send_bytes(bytes.into()).await {
                            log::debug!("port forward stream send failed: {:?}", e);
                            break;
                        }
                    }
                    _ => break,
                }
            },
            res = stream.next() => {
                match res {
                    Some(Ok(bytes)) => {
                        if let Err(e) = forward.send(bytes).await {
                            log::debug!("port forward local socket send failed: {:?}", e);
                            break;
                        }
                    }
                    _ => break,
                }
            },
        }
    }
    Ok(())
}
