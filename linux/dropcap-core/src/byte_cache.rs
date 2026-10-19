// 바이트 상한 캐시(최근 사용 순) — 화면의 사진 텍스처·Cairo 표면을 장 수가 아니라 풀린 크기로 묶는다
// (맥 ImageMemoryCache: 장 수(160장)로만 묶으면 1400px RGBA 사진만으로 수백 MB~1GB).
// GTK 없이 시험할 수 있게 값의 종류는 가리지 않는다(값 하나의 크기는 넣는 쪽이 알려 준다).
use std::collections::{BTreeMap, HashMap};

pub const MB: usize = 1 << 20;
// 화면 사진 텍스처 상한(맥과 같음)
pub const TEXTURE_LIMIT: usize = 64 * MB;
// 분야 사진(흐린 바탕 + 원래 그림) 표면 상한
pub const SECTION_SURFACE_LIMIT: usize = 48 * MB;

pub struct ByteLru<V: Clone> {
    limit: usize,
    total: usize,
    tick: u64,
    map: HashMap<String, (V, usize, u64)>, // 값 · 크기 · 마지막으로 쓴 때
    order: BTreeMap<u64, String>,         // 마지막으로 쓴 때 → 주소(오래된 것이 앞)
}

impl<V: Clone> ByteLru<V> {
    pub fn new(limit: usize) -> Self {
        ByteLru { limit, total: 0, tick: 0, map: HashMap::new(), order: BTreeMap::new() }
    }

    pub fn get(&mut self, key: &str) -> Option<V> {
        self.tick += 1;
        let t = self.tick;
        let e = self.map.get_mut(key)?;
        self.order.remove(&e.2);
        e.2 = t;
        self.order.insert(t, key.to_string());
        Some(e.0.clone())
    }

    pub fn contains(&self, key: &str) -> bool {
        self.map.contains_key(key)
    }

    // 넣고, 상한을 넘으면 가장 오래 안 쓴 것부터 뺀다(방금 넣은 것은 상한보다 커도 남긴다 — 지금 그리는 사진)
    pub fn insert(&mut self, key: &str, value: V, cost: usize) {
        self.remove(key);
        self.tick += 1;
        self.map.insert(key.to_string(), (value, cost, self.tick));
        self.order.insert(self.tick, key.to_string());
        self.total += cost;
        while self.total > self.limit && self.map.len() > 1 {
            let Some((_, old)) = self.order.pop_first() else { break };
            if let Some((_, c, _)) = self.map.remove(&old) {
                self.total -= c;
            }
        }
    }

    pub fn remove(&mut self, key: &str) {
        if let Some((_, c, t)) = self.map.remove(key) {
            self.order.remove(&t);
            self.total -= c;
        }
    }

    pub fn clear(&mut self) {
        self.map.clear();
        self.order.clear();
        self.total = 0;
    }

    pub fn bytes(&self) -> usize {
        self.total
    }
    pub fn len(&self) -> usize {
        self.map.len()
    }
    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }
}

// 풀린 RGBA 그림 하나의 크기
pub fn rgba_bytes(w: i32, h: i32) -> usize {
    (w.max(0) as usize) * (h.max(0) as usize) * 4
}

// 칸(box)을 꽉 채우는(cover) 데 필요한 만큼으로 줄인 크기. 작은 그림은 키우지 않는다.
// 카드마다 원본(최대 1400px) 크기 Cairo 표면 사본을 두지 않게 — box 는 화면 배율을 곱한 픽셀
pub fn cover_size(w: i32, h: i32, box_w: i32, box_h: i32) -> (i32, i32) {
    if w <= 0 || h <= 0 || box_w <= 0 || box_h <= 0 {
        return (w.max(0), h.max(0));
    }
    let k = (box_w as f64 / w as f64).max(box_h as f64 / h as f64);
    if k >= 1.0 {
        return (w, h);
    }
    (((w as f64 * k).round() as i32).max(1), ((h as f64 * k).round() as i32).max(1))
}
