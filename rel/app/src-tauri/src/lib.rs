use elixirkit::PubSub;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager, Wry};
use tauri_plugin_clipboard_manager::ClipboardExt;
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons, MessageDialogKind};
use tauri_plugin_updater::UpdaterExt;

#[cfg(target_os = "linux")]
use tauri_plugin_deep_link::DeepLinkExt;

const APP_NAME: &str = "Avcs";
const TRAY_ID: &str = "avcs-tray";

pub fn run() {
    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            let urls = extract_open_urls(argv);
            if let Some(state) = app.try_state::<AppState>() {
                for url in urls {
                    state.publish_open(&url);
                }
            }
        }))
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .setup(|app| {
            let log_path = log_path();
            ensure_parent_dir(&log_path)?;
            write_log(&log_path, "starting Avcs desktop launcher");

            let pubsub = PubSub::listen("tcp://127.0.0.1:0")?;
            let port = select_port()?;
            let app_handle = app.handle();

            let open_item = menu_item(app_handle, "open", "Open Avcs", true, "cmd+o");
            let settings_item = menu_item(app_handle, "settings", "Settings", true, "cmd+,");
            let copy_url_item = menu_item(app_handle, "copy-url", "Copy URL", false, "cmd+c");
            let logs_item = menu_item(app_handle, "view-logs", "View Logs", true, "cmd+l");
            let check_updates_item =
                menu_item(app_handle, "check-updates", "Check for Updates...", true, "");
            let quit_item = menu_item(app_handle, "quit", "Quit", true, "cmd+q");

            let tray_menu = Menu::with_items(
                app_handle,
                &[
                    &open_item,
                    &settings_item,
                    &PredefinedMenuItem::separator(app_handle)?,
                    &copy_url_item,
                    &logs_item,
                    &PredefinedMenuItem::separator(app_handle)?,
                    &check_updates_item,
                    &quit_item,
                ],
            )?;

            let tray = TrayIconBuilder::with_id(TRAY_ID)
                .tooltip(APP_NAME)
                .icon(app_handle.default_window_icon().unwrap().clone())
                .show_menu_on_left_click(false)
                .on_menu_event(move |app, event| match event.id.as_ref() {
                    "open" => app.state::<AppState>().publish_open(""),
                    "settings" => app.state::<AppState>().publish_open("/web/settings"),
                    "copy-url" => {
                        if let Some(url) = app.state::<AppState>().get_url() {
                            let _ = app.clipboard().write_text(url);
                        }
                    }
                    "view-logs" => app.state::<AppState>().publish_open("/logs"),
                    "check-updates" => check_for_updates(app.clone()),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .build(app_handle)?;

            let state = AppState::new(
                pubsub.clone(),
                log_path.clone(),
                tray_menu,
                copy_url_item,
                tray,
            );
            let child_slot = state.child.clone();
            app.manage(state);

            let initial_urls = extract_open_urls(std::env::args().skip(1).collect());
            if initial_urls.is_empty() {
                app.state::<AppState>().publish_open("");
            } else {
                for url in initial_urls {
                    app.state::<AppState>().publish_open(&url);
                }
            }

            #[cfg(target_os = "linux")]
            {
                let _ = app.deep_link().register_all();
            }

            let handle = app.handle().clone();
            pubsub.subscribe("messages", move |msg| {
                if let Some(url) = msg.strip_prefix(b"ready:") {
                    let url = String::from_utf8_lossy(url).into_owned();
                    handle.state::<AppState>().set_ready(url);
                } else {
                    write_log(
                        &handle.state::<AppState>().log_path,
                        &format!("unexpected desktop message: {}", String::from_utf8_lossy(msg)),
                    );
                }
            });

            let handle = app.handle().clone();
            let release_log_path = log_path.clone();
            tauri::async_runtime::spawn_blocking(move || {
                let child = match start_release(&handle, &pubsub, port, &release_log_path) {
                    Ok(child) => child,
                    Err(error) => {
                        write_log(
                            &release_log_path,
                            &format!("failed to start Phoenix release: {error}"),
                        );
                        show_error_dialog(
                            &handle,
                            "Avcs Failed to Start",
                            format!(
                                "Failed to start the Avcs Phoenix release.\n\nLogs: {}",
                                release_log_path.display()
                            ),
                        );
                        handle.exit(1);
                        return;
                    }
                };

                {
                    let mut guard = child_slot.lock().unwrap();
                    *guard = Some(child);
                }

                monitor_release(handle, child_slot, release_log_path);
            });

            let app_handle_for_updates = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let _ = check_for_updates_on_boot(app_handle_for_updates).await;
            });

            Ok(())
        });

    let app = builder
        .build(tauri::generate_context!())
        .expect("error while building tauri application");

    app.run(|app_handle, event| match event {
        #[cfg(target_os = "macos")]
        tauri::RunEvent::Opened { urls } => {
            if let Some(state) = app_handle.try_state::<AppState>() {
                for url in normalize_urls(urls) {
                    state.publish_open(&url);
                }
            }
        }

        #[cfg(target_os = "macos")]
        tauri::RunEvent::Reopen { .. } => {
            if let Some(state) = app_handle.try_state::<AppState>() {
                state.publish_open("");
            }
        }

        tauri::RunEvent::ExitRequested { .. } => {
            if let Some(state) = app_handle.try_state::<AppState>() {
                state.terminate();
            }
        }

        _ => {}
    });
}

struct AppState {
    pubsub: PubSub,
    ready: Arc<Mutex<bool>>,
    pending_open: Arc<Mutex<Vec<String>>>,
    current_url: Arc<Mutex<Option<String>>>,
    child: Arc<Mutex<Option<Child>>>,
    log_path: PathBuf,
    tray_menu: Menu<Wry>,
    copy_url_item: MenuItem<Wry>,
    tray: tauri::tray::TrayIcon<Wry>,
    tray_menu_ready: Arc<Mutex<bool>>,
}

impl AppState {
    fn new(
        pubsub: PubSub,
        log_path: PathBuf,
        tray_menu: Menu<Wry>,
        copy_url_item: MenuItem<Wry>,
        tray: tauri::tray::TrayIcon<Wry>,
    ) -> Self {
        Self {
            pubsub,
            ready: Arc::new(Mutex::new(false)),
            pending_open: Arc::new(Mutex::new(Vec::new())),
            current_url: Arc::new(Mutex::new(None)),
            child: Arc::new(Mutex::new(None)),
            log_path,
            tray_menu,
            copy_url_item,
            tray,
            tray_menu_ready: Arc::new(Mutex::new(false)),
        }
    }

    fn publish_open(&self, url: &str) {
        if *self.ready.lock().unwrap() {
            if let Err(error) = self
                .pubsub
                .broadcast("messages", format!("open:{url}").as_bytes())
            {
                write_log(&self.log_path, &format!("failed to publish open event: {error}"));
            }
            return;
        }

        if let Ok(mut pending) = self.pending_open.lock() {
            pending.push(url.to_string());
        }
    }

    fn set_ready(&self, url: String) {
        self.set_url(url);
        self.enable_tray_menu();

        *self.ready.lock().unwrap() = true;

        if let Ok(mut pending) = self.pending_open.lock() {
            for url in pending.drain(..) {
                if let Err(error) = self
                    .pubsub
                    .broadcast("messages", format!("open:{url}").as_bytes())
                {
                    write_log(
                        &self.log_path,
                        &format!("failed to flush open event: {error}"),
                    );
                }
            }
        }
    }

    fn set_url(&self, url: String) {
        if let Ok(mut guard) = self.current_url.lock() {
            *guard = Some(url);
        }
    }

    fn get_url(&self) -> Option<String> {
        self.current_url.lock().ok().and_then(|url| url.clone())
    }

    fn enable_tray_menu(&self) {
        let should_set = self
            .tray_menu_ready
            .lock()
            .map(|mut ready| {
                if *ready {
                    false
                } else {
                    *ready = true;
                    true
                }
            })
            .unwrap_or(false);

        if !should_set {
            return;
        }

        let _ = self.tray.set_menu(Some(self.tray_menu.clone()));
        let _ = self.tray.set_show_menu_on_left_click(true);
        let _ = self.copy_url_item.set_enabled(true);
    }

    fn terminate(&self) {
        let mut guard = self.child.lock().unwrap();

        if let Some(child) = guard.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
            write_log(&self.log_path, "terminated Avcs Phoenix release");
        }

        *guard = None;
    }
}

fn start_release(
    handle: &AppHandle,
    pubsub: &PubSub,
    port: u16,
    log_path: &Path,
) -> tauri::Result<Child> {
    let mut cmd = if cfg!(debug_assertions) {
        let mix_root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..");
        let mut cmd = elixirkit::mix("phx.server", &[]);
        cmd.current_dir(mix_root);
        cmd.env("MIX_TARGET", "app");
        cmd
    } else {
        let release_dir = handle.path().resource_dir()?.join("rel");
        elixirkit::release(&release_dir, "app")
    };

    write_log(
        log_path,
        &format!("starting Avcs Phoenix release on port {port}"),
    );

    cmd.env("AVCS_DESKTOP", "true")
        .env("ELIXIRKIT_PUBSUB", pubsub.url())
        .env("LOG_PATH", log_path.display().to_string())
        .env("PHX_SERVER", "true")
        .env("PORT", port.to_string())
        .env("RELEASE_DISTRIBUTION", "none")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let mut child = cmd.spawn()?;

    if let Some(stdout) = child.stdout.take() {
        spawn_output_thread(stdout, log_path.to_path_buf(), "stdout");
    }

    if let Some(stderr) = child.stderr.take() {
        spawn_output_thread(stderr, log_path.to_path_buf(), "stderr");
    }

    Ok(child)
}

fn monitor_release(
    app_handle: AppHandle,
    child_slot: Arc<Mutex<Option<Child>>>,
    log_path: PathBuf,
) {
    loop {
        let status = {
            let mut guard = child_slot.lock().unwrap();

            match guard.as_mut() {
                Some(child) => match child.try_wait() {
                    Ok(Some(status)) => {
                        *guard = None;
                        Some(status)
                    }
                    Ok(None) => None,
                    Err(error) => {
                        write_log(&log_path, &format!("failed to wait for release: {error}"));
                        app_handle.exit(1);
                        return;
                    }
                },
                None => return,
            }
        };

        if let Some(status) = status {
            let code = status.code().unwrap_or(1);
            write_log(&log_path, &format!("Phoenix release exited with status {code}"));
            if code != 0 {
                show_exit_dialog(&app_handle, code, &log_path);
            }
            app_handle.exit(code);
            return;
        }

        std::thread::sleep(Duration::from_millis(250));
    }
}

fn select_port() -> tauri::Result<u16> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let port = listener.local_addr()?.port();
    drop(listener);
    Ok(port)
}

fn spawn_output_thread<R>(mut stream: R, log_path: PathBuf, label: &'static str)
where
    R: Read + Send + 'static,
{
    std::thread::spawn(move || {
        let mut buffer = [0_u8; 4096];

        loop {
            match stream.read(&mut buffer) {
                Ok(0) => break,
                Ok(count) => {
                    let text = String::from_utf8_lossy(&buffer[..count]);
                    write_log(&log_path, &format!("[{label}] {text}"));
                }
                Err(error) => {
                    write_log(&log_path, &format!("failed to read {label}: {error}"));
                    break;
                }
            }
        }
    });
}

fn menu_item(
    app_handle: &AppHandle,
    id: &str,
    label: &str,
    is_enabled: bool,
    accelerator: &str,
) -> MenuItem<Wry> {
    let accel = if cfg!(target_os = "macos") && !accelerator.is_empty() {
        Some(accelerator)
    } else {
        None
    };

    MenuItem::with_id(app_handle, id, label, is_enabled, accel)
        .expect("failed to create menu item")
}

fn show_exit_dialog(handle: &AppHandle, code: i32, log_path: &Path) {
    handle
        .dialog()
        .message(format!(
            "Avcs exited with exit code {}.\nLogs available at: {}",
            code,
            log_path.display()
        ))
        .kind(MessageDialogKind::Error)
        .title("Avcs Exited")
        .blocking_show();
}

fn show_error_dialog(app: &AppHandle, title: impl Into<String>, message: impl Into<String>) {
    app.dialog()
        .message(message)
        .kind(MessageDialogKind::Error)
        .title(title)
        .blocking_show();
}

fn extract_open_urls(args: Vec<String>) -> Vec<String> {
    let mut urls = Vec::new();

    for arg in args {
        if let Some(url) = normalize_open_url(&arg) {
            urls.push(url);
        }
    }

    urls
}

#[cfg(target_os = "macos")]
fn normalize_urls(urls: Vec<url::Url>) -> Vec<String> {
    urls.into_iter()
        .filter_map(|url| normalize_open_url(url.as_str()))
        .collect()
}

fn normalize_open_url(input: &str) -> Option<String> {
    let parsed = if cfg!(windows) && input.len() >= 2 && input.chars().nth(1) == Some(':') {
        url::Url::from_file_path(PathBuf::from(input)).ok()?
    } else if input.starts_with('/') {
        url::Url::from_file_path(input).ok()?
    } else {
        url::Url::parse(input).ok()?
    };

    match parsed.scheme() {
        "avcs" => Some(parsed.to_string()),
        "file" => Some(parsed.to_string()),
        _ => None,
    }
}

async fn check_for_updates_on_boot(app: AppHandle) -> tauri_plugin_updater::Result<()> {
    if let Some(update) = app.updater()?.check().await? {
        let should_install = app
            .dialog()
            .message(format!(
                "Version {} is available.\n\nWould you like to download and install it now?",
                update.version
            ))
            .kind(MessageDialogKind::Info)
            .title("Update Available")
            .buttons(MessageDialogButtons::OkCancel)
            .blocking_show();

        if should_install {
            update.download_and_install(|_, _| {}, || {}).await?;
            app.restart();
        }
    }

    Ok(())
}

fn check_for_updates(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        if let Err(error) = check_for_updates_async(app.clone()).await {
            show_error_dialog(
                &app,
                "Update Check Failed",
                format!("Failed to check for updates: {error}"),
            );
        }
    });
}

async fn check_for_updates_async(app: AppHandle) -> tauri_plugin_updater::Result<()> {
    if let Some(update) = app.updater()?.check().await? {
        let should_install = app
            .dialog()
            .message(format!(
                "Version {} is available.\n\nWould you like to download and install it now?",
                update.version
            ))
            .kind(MessageDialogKind::Info)
            .title("Update Available")
            .buttons(MessageDialogButtons::OkCancel)
            .blocking_show();

        if should_install {
            update.download_and_install(|_, _| {}, || {}).await?;
            app.restart();
        }
    } else {
        app.dialog()
            .message(format!(
                "You're running the latest version:\n\nv{}",
                app.package_info().version
            ))
            .kind(MessageDialogKind::Info)
            .title("No Updates Available")
            .blocking_show();
    }

    Ok(())
}

fn log_path() -> PathBuf {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));

    home.join("Library").join("Logs").join(APP_NAME).join("avcs.log")
}

fn ensure_parent_dir(path: &Path) -> tauri::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    Ok(())
}

fn write_log(path: &Path, message: &str) {
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }

    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{message}");
    }
}
