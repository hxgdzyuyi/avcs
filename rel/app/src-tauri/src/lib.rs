use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};

const APP_NAME: &str = "Avcs";
const HEALTH_TIMEOUT: Duration = Duration::from_secs(60);

pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            let log_path = log_path();
            ensure_parent_dir(&log_path)?;
            write_log(&log_path, "starting Avcs desktop shell");

            let port = select_port()?;
            let release_dir = app.path().resource_dir()?.join("rel");
            let child = start_release(&release_dir, port, &log_path)?;
            let state = BackendState::new(log_path.clone());
            let child_slot = state.child.clone();

            app.manage(state);

            {
                let mut guard = child_slot.lock().unwrap();
                *guard = Some(child);
            }

            if !wait_for_health(port, HEALTH_TIMEOUT) {
                write_log(
                    &log_path,
                    &format!("Phoenix did not become ready within {:?}", HEALTH_TIMEOUT),
                );

                if let Some(state) = app.try_state::<BackendState>() {
                    state.terminate();
                }

                return Err(format!(
                    "Avcs Phoenix release did not become ready. See {}",
                    log_path.display()
                )
                .into());
            }

            let url = format!("http://127.0.0.1:{port}/");
            WebviewWindowBuilder::new(app, "main", WebviewUrl::External(url.parse()?))
                .title(APP_NAME)
                .inner_size(1280.0, 820.0)
                .min_inner_size(960.0, 640.0)
                .build()?;

            monitor_release(app.handle().clone(), child_slot, log_path);
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { .. } = event {
                window.app_handle().exit(0);
            }
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app_handle, event| {
            if let tauri::RunEvent::ExitRequested { .. } = event {
                if let Some(state) = app_handle.try_state::<BackendState>() {
                    state.terminate();
                }
            }
        });
}

struct BackendState {
    child: Arc<Mutex<Option<Child>>>,
    log_path: PathBuf,
}

impl BackendState {
    fn new(log_path: PathBuf) -> Self {
        Self {
            child: Arc::new(Mutex::new(None)),
            log_path,
        }
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

fn start_release(release_dir: &Path, port: u16, log_path: &Path) -> tauri::Result<Child> {
    let executable = release_dir.join("bin").join("app");
    write_log(
        log_path,
        &format!(
            "starting Phoenix release {} on port {}",
            executable.display(),
            port
        ),
    );

    let mut command = Command::new(executable);
    command
        .arg("start")
        .env("AVCS_DESKTOP", "true")
        .env("PHX_SERVER", "true")
        .env("PORT", port.to_string())
        .env("RELEASE_DISTRIBUTION", "none")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let mut child = command.spawn()?;

    if let Some(stdout) = child.stdout.take() {
        spawn_output_thread(stdout, log_path.to_path_buf(), "stdout");
    }

    if let Some(stderr) = child.stderr.take() {
        spawn_output_thread(stderr, log_path.to_path_buf(), "stderr");
    }

    Ok(child)
}

fn monitor_release(
    app_handle: tauri::AppHandle,
    child_slot: Arc<Mutex<Option<Child>>>,
    log_path: PathBuf,
) {
    tauri::async_runtime::spawn_blocking(move || loop {
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
                        *guard = None;
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
            app_handle.exit(code);
            return;
        }

        std::thread::sleep(Duration::from_millis(250));
    });
}

fn wait_for_health(port: u16, timeout: Duration) -> bool {
    let started_at = Instant::now();

    while started_at.elapsed() < timeout {
        if health_request(port) {
            return true;
        }

        std::thread::sleep(Duration::from_millis(250));
    }

    false
}

fn health_request(port: u16) -> bool {
    let address = SocketAddr::from(([127, 0, 0, 1], port));

    let Ok(mut stream) = TcpStream::connect_timeout(&address, Duration::from_millis(500)) else {
        return false;
    };

    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(500)));

    if stream
        .write_all(b"GET /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        .is_err()
    {
        return false;
    }

    let mut response = String::new();

    stream.read_to_string(&mut response).is_ok()
        && response.contains(" 200 ")
        && response.contains("\"status\":\"ok\"")
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
