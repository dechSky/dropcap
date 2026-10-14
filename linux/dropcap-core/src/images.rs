// 피드에서 온 사진 주소는 믿지 않으므로 사진은 모두 이것으로만 받는다(S-07 · 맥 UI/RemoteImage.swift):
// 공개 주소만(net 의 안전 검사), 8MB 까지, 최대 1400px 로 줄여 디스크에 JPEG 로 담아 둔다. 600개 넘으면 500개로.
use crate::net;
use futures::future::{BoxFuture, FutureExt, Shared};
use once_cell::sync::Lazy;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;

pub const MAX_BYTES: usize = 8 << 20;
pub const MAX_PIXELS: u32 = 1400;
pub const DISK_LIMIT: usize = 600;
pub const DISK_KEEP: usize = 500;

pub struct ImageLoader {
    dir: PathBuf,
    inflight: Mutex<HashMap<String, Shared<BoxFuture<'static, Option<PathBuf>>>>>,
    writes: AtomicUsize,
}

static LOADER: Lazy<Mutex<Option<&'static ImageLoader>>> = Lazy::new(|| Mutex::new(None));

pub fn shared() -> &'static ImageLoader {
    let mut g = LOADER.lock().unwrap();
    if let Some(l) = *g {
        return l;
    }
    let l: &'static ImageLoader = Box::leak(Box::new(ImageLoader::new(crate::store::DIR.join("images"))));
    *g = Some(l);
    l
}

pub fn file_name(url: &str) -> String {
    let h = Sha256::digest(url.as_bytes());
    let hex: String = h.iter().map(|b| format!("{b:02x}")).collect();
    format!("{}.jpg", &hex[..24])
}

// 줄이고 JPEG 로(품질 82)
pub fn shrink(data: &[u8]) -> Option<Vec<u8>> {
    if data.len() >= MAX_BYTES {
        return None;
    }
    let img = image::load_from_memory(data).ok()?;
    let img = if img.width() > MAX_PIXELS || img.height() > MAX_PIXELS { img.thumbnail(MAX_PIXELS, MAX_PIXELS) } else { img };
    let rgb = img.to_rgb8();
    let mut out = Vec::new();
    let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 82);
    enc.encode_image(&rgb).ok()?;
    Some(out)
}

impl ImageLoader {
    pub fn new(dir: PathBuf) -> ImageLoader {
        let _ = std::fs::create_dir_all(&dir);
        ImageLoader { dir, inflight: Mutex::new(HashMap::new()), writes: AtomicUsize::new(0) }
    }

    // 디스크에 담긴 사진 파일 경로. 같은 주소를 동시에 부르면 한 번만 받는다.
    pub async fn image(&'static self, url: &str) -> Option<PathBuf> {
        let f = self.dir.join(file_name(url));
        if f.exists() {
            return Some(f);
        }
        let existing = self.inflight.lock().unwrap().get(url).cloned();
        if let Some(t) = existing {
            return t.await;
        }
        let u = url.to_string();
        let fut = async move { self.load(&u).await }.boxed().shared();
        self.inflight.lock().unwrap().insert(url.to_string(), fut.clone());
        let r = fut.await;
        self.inflight.lock().unwrap().remove(url);
        r
    }

    async fn load(&self, url: &str) -> Option<PathBuf> {
        let f = self.dir.join(file_name(url));
        let r = net::get(url, &[("accept", "image/*".into())], crate::feed_service::FetchLimit::Image.bytes()).await.ok()?;
        if !(200..300).contains(&r.status) {
            return None;
        }
        let jpg = tokio::task::spawn_blocking(move || shrink(&r.data)).await.ok()??;
        crate::store::write_atomic(&f, &jpg).ok()?;
        self.prune();
        Some(f)
    }

    fn prune(&self) {
        if self.writes.fetch_add(1, Ordering::SeqCst) % 20 != 19 {
            return;
        }
        prune_dir(&self.dir, DISK_LIMIT, DISK_KEEP);
    }
}

pub fn prune_dir(dir: &std::path::Path, limit: usize, keep: usize) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    let mut files: Vec<(PathBuf, std::time::SystemTime)> =
        rd.flatten().map(|e| (e.path(), e.metadata().and_then(|m| m.modified()).unwrap_or(std::time::UNIX_EPOCH))).collect();
    if files.len() <= limit {
        return;
    }
    files.sort_by_key(|f| f.1);
    let n = files.len() - keep;
    for (p, _) in files.into_iter().take(n) {
        let _ = std::fs::remove_file(p);
    }
}

