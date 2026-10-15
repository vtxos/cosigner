//! A small host for `cosigner.wasm`: the runtime's part, played by fakes, so a test can drive the
//! very component a release ships, and not a native build of its library.
//!
//! It links the component as the runtime does: all of WASI, `wasi:http` both ways, and the four
//! interfaces the runtime adds (tasks, notify, streams, telemetry). Each call gets a fresh instance
//! over one tenant directory preopened as `/`, so state survives only through what the cosigner
//! seals, as in an enclave.
//!
//! What it fakes, and how:
//!
//! - **Tasks** are queued, and run when the test asks: [`Host::run_due`] is the runtime's scheduler,
//!   in miniature. Each run is a fresh instance calling the `run-task` export.
//! - **The runtime's rule for background work** is kept: only a request may arm a task, cancel
//!   one, enrol a device or open a stream. A background run may wake its owner and nothing more,
//!   and here, as in the runtime, anything else it asks for is refused.
//! - **Wakes, devices and streams** are recorded for the test to read.
//! - **The ASP** is answered in process: the component's outgoing HTTP to [`ASP_ORIGIN`] never
//!   leaves the host, and anything else is denied. See [`Asp`].
//! - **Telemetry** is accepted and dropped.

use std::collections::BTreeMap;
use std::path::Path;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::Duration;

use anyhow::{anyhow, bail, Context as _, Result};
use bytes::{Buf, Bytes, BytesMut};
use http_body_util::{BodyExt, Full};
use wasmtime::component::{
    Component, ComponentType, InstancePre, Lift, Linker, Resource, ResourceTable, ResourceType,
};
use wasmtime::{Engine, Store};
use wasmtime_wasi::{DirPerms, FilePerms, WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};
use wasmtime_wasi_http::p2::bindings::http::types::{ErrorCode, Scheme};
use wasmtime_wasi_http::p2::bindings::ProxyPre;
use wasmtime_wasi_http::p2::body::HyperOutgoingBody;
use wasmtime_wasi_http::p2::types::{
    HostFutureIncomingResponse, IncomingResponse, OutgoingRequestConfig,
};
use wasmtime_wasi_http::p2::{HttpResult, WasiHttpCtxView, WasiHttpHooks, WasiHttpView};
use wasmtime_wasi_http::WasiHttpCtx;

/// Where the component is told its ASP is (`ASP_URL`), and the only origin it can reach.
pub const ASP_ORIGIN: &str = "http://asp.test";

/// One queued task, as the runtime keeps it.
#[derive(Clone, Debug)]
pub struct Task {
    pub payload: Vec<u8>,
    pub run_at_ms: u64,
    pub interval_ms: Option<u64>,
    pub cancelled: bool,
    pub runs: u64,
}

/// What the fakes hold and recorded, shared by every instance.
#[derive(Default)]
pub struct Runtime {
    pub tasks: Mutex<BTreeMap<String, Task>>,
    pub devices: Mutex<Vec<String>>,
    pub wakes: Mutex<Vec<(String, Option<String>)>>,
    /// Held connections, by id, and the origin each was opened to.
    pub streams: Mutex<BTreeMap<String, String>>,
    pub sent: Mutex<Vec<(String, Vec<u8>)>>,
    pub asp: Mutex<Asp>,
}

const NOT_INTERACTIVE: &str = "only a request may do this; a background run may only wake";

impl Runtime {
    fn enqueue(&self, interactive: bool, id: String, payload: Vec<u8>, run_at_ms: u64, interval_ms: Option<u64>) -> Result<(), String> {
        if !interactive {
            return Err(NOT_INTERACTIVE.into());
        }
        let mut tasks = self.tasks.lock().unwrap();
        if let Some(old) = tasks.get(&id) {
            // An id is an idempotency key: the same input again is a no-op, and different input is
            // refused until the old record is cancelled and forgotten.
            if old.payload != payload || old.run_at_ms != run_at_ms || old.interval_ms != interval_ms {
                return Err("task id already used with different input".into());
            }
            return Ok(());
        }
        tasks.insert(id, Task { payload, run_at_ms, interval_ms, cancelled: false, runs: 0 });
        Ok(())
    }

    fn cancel(&self, interactive: bool, id: &str) -> Result<(), String> {
        if !interactive {
            return Err(NOT_INTERACTIVE.into());
        }
        match self.tasks.lock().unwrap().get_mut(id) {
            Some(task) => {
                task.cancelled = true;
                Ok(())
            }
            None => Err("no such task".into()),
        }
    }

    fn forget(&self, interactive: bool, id: &str) -> Result<(), String> {
        if !interactive {
            return Err(NOT_INTERACTIVE.into());
        }
        let mut tasks = self.tasks.lock().unwrap();
        match tasks.get(id) {
            Some(task) if task.cancelled => {
                tasks.remove(id);
                Ok(())
            }
            Some(_) => Err("task is still active".into()),
            None => Err("no such task".into()),
        }
    }

    fn register_device(&self, interactive: bool, token: String) -> Result<(), String> {
        if !interactive {
            return Err(NOT_INTERACTIVE.into());
        }
        if !(32..=512).contains(&token.len()) {
            return Err("a device token is 32 to 512 characters".into());
        }
        let mut devices = self.devices.lock().unwrap();
        if !devices.contains(&token) {
            devices.push(token);
        }
        Ok(())
    }

    fn forget_device(&self, interactive: bool, token: &str) -> Result<(), String> {
        if !interactive {
            return Err(NOT_INTERACTIVE.into());
        }
        self.devices.lock().unwrap().retain(|held| held != token);
        Ok(())
    }

    fn stream_open(&self, interactive: bool, id: String, origin: String) -> Result<(), String> {
        if !interactive {
            return Err(NOT_INTERACTIVE.into());
        }
        let mut streams = self.streams.lock().unwrap();
        match streams.get(&id) {
            Some(held) if *held != origin => Err(format!("a stream with that id is open to {held}")),
            _ => {
                streams.insert(id, origin);
                Ok(())
            }
        }
    }

    pub fn tasks(&self) -> BTreeMap<String, Task> {
        self.tasks.lock().unwrap().clone()
    }

    pub fn devices(&self) -> Vec<String> {
        self.devices.lock().unwrap().clone()
    }

    pub fn wakes(&self) -> Vec<(String, Option<String>)> {
        self.wakes.lock().unwrap().clone()
    }
}

/// The ASP, in process: the REST calls the component makes, answered from what a test sets here,
/// and every call recorded.
#[derive(Default)]
pub struct Asp {
    /// `GET /v1/info`: the gateway's JSON for `ArkInfo`.
    pub info: serde_json::Value,
    /// Refuse `registerIntent`, as an ASP does that will not take the intent.
    pub refuse_registration: bool,
    /// What `GET /v1/batch/events` streams, each as one server-sent event: the gateway's JSON for
    /// one `GetEventStreamResponse`. The stream ends after the last.
    pub events: Vec<serde_json::Value>,
    /// `(method and path, body)` of every call, in order.
    pub calls: Vec<(String, String)>,
    registrations: u32,
}

impl Asp {
    fn answer(&mut self, method: &str, path: &str, body: &[u8]) -> (u16, &'static str, Bytes) {
        self.calls.push((format!("{method} {path}"), String::from_utf8_lossy(body).into()));
        let json = |v: serde_json::Value| (200, "application/json", Bytes::from(v.to_string()));
        match (method, path) {
            ("GET", "/v1/info") => json(self.info.clone()),
            ("POST", "/v1/batch/registerIntent") if self.refuse_registration => {
                (400, "application/json", Bytes::from(r#"{"message":"refused"}"#))
            }
            ("POST", "/v1/batch/registerIntent") => {
                self.registrations += 1;
                json(serde_json::json!({ "intentId": format!("intent-{}", self.registrations) }))
            }
            ("GET", "/v1/batch/events") => {
                let stream: String =
                    self.events.iter().map(|e| format!("data: {e}\n\n")).collect();
                (200, "text/event-stream", Bytes::from(stream))
            }
            ("POST", "/v1/batch/ack")
            | ("POST", "/v1/batch/tree/submitNonces")
            | ("POST", "/v1/batch/tree/submitSignatures")
            | ("POST", "/v1/batch/submitForfeitTxs") => json(serde_json::json!({})),
            _ => (404, "text/plain", Bytes::from("no such endpoint")),
        }
    }

    /// The calls made, as `method path`.
    pub fn called(&self) -> Vec<String> {
        self.calls.iter().map(|(call, _)| call.clone()).collect()
    }
}

/// One instance's state: WASI over the tenant directory, `wasi:http`, and the fakes.
pub struct State {
    wasi: WasiCtx,
    table: ResourceTable,
    http: WasiHttpCtx,
    hooks: Egress,
    runtime: Arc<Runtime>,
    /// A request (true) or a background run (false). See the module's notes.
    interactive: bool,
}

impl WasiView for State {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}

impl WasiHttpView for State {
    fn http(&mut self) -> WasiHttpCtxView<'_> {
        WasiHttpCtxView { ctx: &mut self.http, table: &mut self.table, hooks: &mut self.hooks }
    }
}

/// The component's outgoing HTTP: [`ASP_ORIGIN`] is answered by the fake ASP, and anything else
/// is denied, as an origin the image does not allow would be.
struct Egress(Arc<Runtime>);

impl WasiHttpHooks for Egress {
    fn send_request(
        &mut self,
        request: hyper::Request<HyperOutgoingBody>,
        _config: OutgoingRequestConfig,
    ) -> HttpResult<HostFutureIncomingResponse> {
        if request.uri().authority().map(|a| a.as_str()) != ASP_ORIGIN.strip_prefix("http://") {
            return Err(ErrorCode::HttpRequestDenied.into());
        }
        let runtime = self.0.clone();
        let handle = wasmtime_wasi::runtime::spawn(async move {
            let (parts, body) = request.into_parts();
            let body = match body.collect().await {
                Ok(collected) => collected.to_bytes(),
                Err(e) => return Ok(Err(e)),
            };
            let (status, content_type, reply) = runtime.asp.lock().unwrap().answer(
                parts.method.as_str(),
                parts.uri.path(),
                &body,
            );
            let resp = hyper::Response::builder()
                .status(status)
                .header("content-type", content_type)
                .body(Full::new(reply).map_err(|never| match never {}).boxed_unsync())
                .expect("a well-formed response");
            Ok(Ok(IncomingResponse {
                resp,
                worker: None,
                between_bytes_timeout: Duration::from_secs(30),
            }))
        });
        Ok(HostFutureIncomingResponse::pending(handle))
    }
}

/// The host: one component, one tenant, and the fakes it runs against.
pub struct Host {
    engine: Engine,
    pre: InstancePre<State>,
    proxy: ProxyPre<State>,
    dir: tempfile::TempDir,
    settings: Vec<(String, String)>,
    pub runtime: Arc<Runtime>,
}

impl Host {
    /// Load [wasm], deployed with [settings]: the guest's environment, as the runtime gives a
    /// guest the settings measured with it. `ASP_URL` is [`ASP_ORIGIN`] unless [settings] say.
    pub fn new(wasm: &Path, settings: &[(&str, &str)]) -> Result<Self> {
        let engine = Engine::default();
        let component = Component::from_file(&engine, wasm)
            .map_err(|e| anyhow!("loading {}: {e}", wasm.display()))?;
        let linker = linker(&engine)?;
        let pre = linker
            .instantiate_pre(&component)
            .map_err(|e| anyhow!("linking the component: {e}"))?;
        let proxy = ProxyPre::new(pre.clone())
            .map_err(|e| anyhow!("the component serves no wasi:http: {e}"))?;
        let mut settings: Vec<(String, String)> =
            settings.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        if !settings.iter().any(|(k, _)| k == "ASP_URL") {
            settings.push(("ASP_URL".into(), ASP_ORIGIN.into()));
        }
        Ok(Self {
            engine,
            pre,
            proxy,
            dir: tempfile::tempdir()?,
            settings,
            runtime: Arc::default(),
        })
    }

    fn store(&self, interactive: bool) -> Result<Store<State>> {
        let mut wasi = WasiCtxBuilder::new();
        wasi.preopened_dir(self.dir.path(), "/", DirPerms::all(), FilePerms::all())?;
        wasi.envs(&self.settings);
        // The guest's own logs, in the test's output.
        wasi.inherit_stdout().inherit_stderr();
        Ok(Store::new(
            &self.engine,
            State {
                wasi: wasi.build(),
                table: ResourceTable::new(),
                http: WasiHttpCtx::new(),
                hooks: Egress(self.runtime.clone()),
                runtime: self.runtime.clone(),
                interactive,
            },
        ))
    }

    /// Open the gRPC stream [method] of `cosigner.v1.Cosigner`, on a fresh instance.
    pub async fn call(&self, method: &str) -> Result<Call> {
        let mut store = self.store(true)?;
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let request = hyper::Request::builder()
            .method("POST")
            .uri(format!("http://cosigner.test/cosigner.v1.Cosigner/{method}"))
            .header("content-type", "application/grpc+proto")
            .body(Inbound(rx))?;
        let (sender, receiver) = tokio::sync::oneshot::channel();
        let req = store.data_mut().http().new_incoming_request(Scheme::Http, request)?;
        let out = store.data_mut().http().new_response_outparam(sender)?;
        let proxy = self.proxy.instantiate_async(&mut store).await?;
        let guest = tokio::spawn(async move {
            proxy.wasi_http_incoming_handler().call_handle(&mut store, req, out).await
        });
        // Not awaited here: a unary call answers only once it has read the whole request, so the
        // head arrives after the test has sent it, not before.
        Ok(Call { tx: Some(tx), head: Some(receiver), body: None, buf: BytesMut::new(), _guest: guest })
    }

    /// A unary call: one message in, one out.
    pub async fn unary<Req: prost::Message, Resp: prost::Message + Default>(
        &self,
        method: &str,
        request: &Req,
    ) -> Result<Resp> {
        let mut call = self.call(method).await?;
        call.send(request);
        call.close();
        let response = call.next().await?;
        let (status, message) = call.finish().await?;
        if status != "0" {
            bail!("{method} ended {status}: {message}");
        }
        Ok(response)
    }

    /// The `run-task` export, as the runtime calls it: a fresh instance, in the background.
    pub async fn run_task(&self, run_id: &str, payload: &[u8]) -> Result<Result<Vec<u8>, String>> {
        let mut store = self.store(false)?;
        let instance = self.pre.instantiate_async(&mut store).await?;
        let run = instance.get_typed_func::<(String, Vec<u8>), (Result<Vec<u8>, String>,)>(
            &mut store, "run-task",
        )?;
        let (result,) = run.call_async(&mut store, (run_id.to_string(), payload.to_vec())).await?;
        Ok(result)
    }

    /// The `on-message` export: a message arriving on the held connection [id].
    pub async fn on_message(&self, id: &str, message_id: &str, payload: &[u8]) -> Result<Result<Vec<u8>, String>> {
        let mut store = self.store(false)?;
        let instance = self.pre.instantiate_async(&mut store).await?;
        let deliver = instance
            .get_typed_func::<(String, String, Vec<u8>), (Result<Vec<u8>, String>,)>(
                &mut store, "on-message",
            )?;
        let (result,) = deliver
            .call_async(&mut store, (id.to_string(), message_id.to_string(), payload.to_vec()))
            .await?;
        Ok(result)
    }

    /// The scheduler: run every live task due by [now_ms], each in its own background run, and
    /// move a repeating one on by its interval. Returns `(task id, what the run returned)`.
    pub async fn run_due(&self, now_ms: u64) -> Result<Vec<(String, Result<Vec<u8>, String>)>> {
        let due: Vec<(String, Task)> = self
            .runtime
            .tasks
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, t)| !t.cancelled && t.run_at_ms <= now_ms)
            .map(|(id, t)| (id.clone(), t.clone()))
            .collect();
        let mut ran = Vec::new();
        for (id, task) in due {
            // `<id>:<generation>:<occurrence>`, the form the runtime gives `run-task`.
            let run_id = format!("{id}:{}:{}", "0".repeat(32), task.runs);
            let result = self.run_task(&run_id, &task.payload).await?;
            if let Some(task) = self.runtime.tasks.lock().unwrap().get_mut(&id) {
                task.runs += 1;
                match task.interval_ms {
                    Some(interval) => task.run_at_ms = now_ms + interval,
                    None => task.cancelled = true,
                }
            }
            ran.push((id, result));
        }
        Ok(ran)
    }
}

/// The client's end of one gRPC stream.
pub struct Call {
    tx: Option<tokio::sync::mpsc::UnboundedSender<Bytes>>,
    head: Option<
        tokio::sync::oneshot::Receiver<Result<hyper::Response<HyperOutgoingBody>, ErrorCode>>,
    >,
    body: Option<HyperOutgoingBody>,
    buf: BytesMut,
    _guest: tokio::task::JoinHandle<wasmtime::Result<()>>,
}

impl Call {
    /// Send one message, framed.
    pub fn send<M: prost::Message>(&self, message: &M) {
        let encoded = message.encode_to_vec();
        let mut frame = BytesMut::with_capacity(5 + encoded.len());
        frame.extend_from_slice(&[0]);
        frame.extend_from_slice(&(encoded.len() as u32).to_be_bytes());
        frame.extend_from_slice(&encoded);
        if let Some(tx) = &self.tx {
            let _ = tx.send(frame.freeze());
        }
    }

    /// End the client's side: it has nothing more to say.
    pub fn close(&mut self) {
        self.tx = None;
    }

    /// The response's body, once the guest has answered with its head.
    async fn body(&mut self) -> Result<&mut HyperOutgoingBody> {
        if let Some(head) = self.head.take() {
            let response = tokio::time::timeout(Duration::from_secs(60), head)
                .await
                .context("the guest did not answer for a minute")?
                .map_err(|_| anyhow!("the guest never answered"))?
                .map_err(|e| anyhow!("the guest failed the request: {e:?}"))?;
            self.body = Some(response.into_body());
        }
        self.body.as_mut().ok_or_else(|| anyhow!("no response"))
    }

    /// The guest's next message. Its trailers instead are an error carrying them.
    pub async fn next<M: prost::Message + Default>(&mut self) -> Result<M> {
        loop {
            if self.buf.len() >= 5 {
                let len = u32::from_be_bytes(self.buf[1..5].try_into().unwrap()) as usize;
                if self.buf.len() >= 5 + len {
                    self.buf.advance(5);
                    let message = self.buf.split_to(len);
                    return Ok(M::decode(message)?);
                }
            }
            let body = self.body().await?;
            let frame = tokio::time::timeout(Duration::from_secs(60), body.frame())
                .await
                .context("the guest said nothing for a minute")?
                .ok_or_else(|| anyhow!("the stream ended before its next message"))?
                .map_err(|e| anyhow!("the stream failed: {e:?}"))?;
            match frame.into_data() {
                Ok(data) => self.buf.extend_from_slice(&data),
                Err(frame) => {
                    let trailers = frame.into_trailers().unwrap_or_default();
                    bail!("the stream ended instead: {}", status_of(&trailers).join(": "));
                }
            }
        }
    }

    /// How the stream ended: `grpc-status` and `grpc-message`.
    pub async fn finish(mut self) -> Result<(String, String)> {
        self.close();
        let body = self.body().await?;
        while let Some(frame) = body.frame().await {
            let frame = frame.map_err(|e| anyhow!("the stream failed: {e:?}"))?;
            if let Ok(trailers) = frame.into_trailers() {
                let [status, message] = status_of(&trailers);
                return Ok((status, message));
            }
        }
        bail!("the stream ended without trailers")
    }
}

fn status_of(trailers: &hyper::HeaderMap) -> [String; 2] {
    let read = |name: &str| {
        trailers.get(name).map(|v| v.to_str().unwrap_or("").to_string()).unwrap_or_default()
    };
    [read("grpc-status"), read("grpc-message")]
}

/// A request body fed by the test as it goes: nothing yet is `Pending`, as on a live connection.
struct Inbound(tokio::sync::mpsc::UnboundedReceiver<Bytes>);

impl http_body::Body for Inbound {
    type Data = Bytes;
    type Error = ErrorCode;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<http_body::Frame<Bytes>, ErrorCode>>> {
        self.0.poll_recv(cx).map(|bytes| bytes.map(|b| Ok(http_body::Frame::data(b))))
    }
}

// --- The runtime's interfaces ------------------------------------------------------------------
//
// The telemetry types only describe the ABI, so a call can be lifted; the fakes read none of it.

#[allow(dead_code)]
#[derive(ComponentType, Lift, Clone, Copy)]
#[component(enum)]
#[repr(u8)]
enum Level {
    #[component(name = "trace")]
    Trace,
    #[component(name = "debug")]
    Debug,
    #[component(name = "info")]
    Info,
    #[component(name = "warn")]
    Warn,
    #[component(name = "error")]
    Error,
}

#[allow(dead_code)]
#[derive(ComponentType, Lift, Clone)]
#[component(record)]
struct Field {
    #[component(name = "key")]
    key: String,
    #[component(name = "value")]
    value: String,
}

#[allow(dead_code)]
#[derive(ComponentType, Lift, Clone, Copy)]
#[component(enum)]
#[repr(u8)]
enum Unit {
    #[component(name = "none")]
    None,
    #[component(name = "count")]
    Count,
    #[component(name = "seconds")]
    Seconds,
    #[component(name = "milliseconds")]
    Milliseconds,
    #[component(name = "bytes")]
    Bytes,
    #[component(name = "kilobytes")]
    Kilobytes,
    #[component(name = "percent")]
    Percent,
}

#[allow(dead_code)]
#[derive(ComponentType, Lift, Clone)]
#[component(record)]
struct Dimension {
    #[component(name = "name")]
    name: String,
    #[component(name = "value")]
    value: String,
}

struct Span;

fn linker(engine: &Engine) -> Result<Linker<State>> {
    let mut linker = Linker::new(engine);
    wasmtime_wasi::p2::add_to_linker_async(&mut linker)?;
    wasmtime_wasi_http::p2::add_only_http_to_linker_async(&mut linker)?;

    let mut queue = linker.instance("enclave:tasks/queue@0.1.0")?;
    queue.func_wrap(
        "enqueue",
        |store, (id, payload, at, interval): (String, Vec<u8>, u64, Option<u64>)| {
            let s: &State = store.data();
            Ok((s.runtime.enqueue(s.interactive, id, payload, at, interval),))
        },
    )?;
    queue.func_wrap("status", |store, (id,): (String,)| {
        let s: &State = store.data();
        let tasks = s.runtime.tasks.lock().unwrap();
        Ok((tasks
            .get(&id)
            .map(|t| serde_json::json!({ "cancelled": t.cancelled, "runs": t.runs }).to_string())
            .ok_or_else(|| "no such task".to_string()),))
    })?;
    queue.func_wrap("cancel", |store, (id,): (String,)| {
        let s: &State = store.data();
        Ok((s.runtime.cancel(s.interactive, &id),))
    })?;
    queue.func_wrap("forget", |store, (id,): (String,)| {
        let s: &State = store.data();
        Ok((s.runtime.forget(s.interactive, &id),))
    })?;

    let mut notify = linker.instance("enclave:notify/notify@0.1.0")?;
    notify.func_wrap("register-device", |store, (token,): (String,)| {
        let s: &State = store.data();
        Ok((s.runtime.register_device(s.interactive, token),))
    })?;
    notify.func_wrap("forget-device", |store, (token,): (String,)| {
        let s: &State = store.data();
        Ok((s.runtime.forget_device(s.interactive, &token),))
    })?;
    notify.func_wrap("devices", |store, (): ()| {
        let s: &State = store.data();
        Ok((Ok::<u32, String>(s.runtime.devices.lock().unwrap().len() as u32),))
    })?;
    notify.func_wrap(
        "wake",
        |store, (category, reference): (String, Option<String>)| {
            let s: &State = store.data();
            s.runtime.wakes.lock().unwrap().push((category, reference));
            Ok((Ok::<(), String>(()),))
        },
    )?;

    let mut connection = linker.instance("enclave:streams/connection@0.1.0")?;
    connection.func_wrap("stream-open", |store, (id, origin): (String, String)| {
        let s: &State = store.data();
        Ok((s.runtime.stream_open(s.interactive, id, origin),))
    })?;
    connection.func_wrap("stream-close", |store, (id,): (String,)| {
        let s: &State = store.data();
        if !s.interactive {
            return Ok((Err(NOT_INTERACTIVE.to_string()),));
        }
        s.runtime.streams.lock().unwrap().remove(&id);
        Ok((Ok(()),))
    })?;
    connection.func_wrap("stream-send", |store, (id, payload): (String, Vec<u8>)| {
        let s: &State = store.data();
        if !s.runtime.streams.lock().unwrap().contains_key(&id) {
            return Ok((Err("that stream is not open".to_string()),));
        }
        s.runtime.sent.lock().unwrap().push((id, payload));
        Ok((Ok(()),))
    })?;
    connection.func_wrap("stream-status", |store, (id,): (String,)| {
        let s: &State = store.data();
        let open = s.runtime.streams.lock().unwrap().contains_key(&id);
        Ok((Ok::<String, String>(serde_json::json!({ "connected": open }).to_string()),))
    })?;

    let mut tracing = linker.instance("enclave:telemetry/tracing@0.1.0")?;
    tracing.resource("span", ResourceType::host::<Span>(), |mut store, rep| {
        store.data_mut().table.delete(Resource::<Span>::new_own(rep))?;
        Ok(())
    })?;
    tracing.func_wrap("event", |_, (_, _, _): (Level, String, Vec<Field>)| Ok(()))?;
    tracing.func_wrap("[constructor]span", |mut store, (_, _, _): (Level, String, Vec<Field>)| {
        Ok((store.data_mut().table.push(Span)?,))
    })?;
    tracing.func_wrap("[method]span.set-field", |_, (_, _, _): (Resource<Span>, String, String)| {
        Ok(())
    })?;
    tracing.func_wrap(
        "[method]span.add-event",
        |_, (_, _, _, _): (Resource<Span>, Level, String, Vec<Field>)| Ok(()),
    )?;
    tracing.func_wrap("[method]span.end", |_, (_,): (Resource<Span>,)| Ok(()))?;

    let mut metrics = linker.instance("enclave:telemetry/metrics@0.1.0")?;
    metrics.func_wrap("counter-add", |_, (_, _, _): (String, f64, Vec<Dimension>)| Ok(()))?;
    for name in ["gauge-set", "histogram-record"] {
        metrics.func_wrap(name, |_, (_, _, _, _): (String, f64, Unit, Vec<Dimension>)| Ok(()))?;
    }

    Ok(linker)
}
