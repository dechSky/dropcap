// 리눅스 아이콘 SVG 는 shared/icon.json(세 판 공통 도형)에서 만든다. 이 시험이 같은지 확인한다.
// 도형을 바꾼 뒤 다시 만들기: DROPCAP_ICON_UPDATE=1 cargo test -p dropcap-core --test icon_svg_tests
use serde_json::Value;
use std::path::PathBuf;

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..")
}

fn num(v: &Value) -> String {
    let f = v.as_f64().unwrap();
    if f.fract() == 0.0 { format!("{}", f as i64) } else { format!("{f}") }
}

// 층(layer) 목록을 SVG 로. tint 가 있으면 모든 면을 그 색으로(상징).
fn svg(v: &Value, layers: &Value, px: u32, unit: u32, tint: Option<&str>, note: &str) -> String {
    let mut defs = String::new();
    let mut body = String::new();
    let tile = v.get("tile").and_then(Value::as_str);
    if let (Some(t), Some(sh)) = (tile, v.get("shadow")) {
        defs += &format!(
            r##"<filter id="s" x="-10%" y="-10%" width="120%" height="125%"><feDropShadow dx="0" dy="{}" stdDeviation="{}" flood-color="#000" flood-opacity="{}"/></filter><clipPath id="c"><path d="{t}"/></clipPath>"##,
            num(&sh["dy"]), num(&sh["sigma"]), num(&sh["opacity"])
        );
        body += &format!(r##"<path d="{t}" fill="#000" filter="url(#s)"/>"##);
    }
    let mut inner = String::new();
    for (i, l) in layers.as_array().unwrap().iter().enumerate() {
        let mut a = format!(r#"d="{}""#, l["d"].as_str().unwrap());
        match (l.get("gradient"), tint) {
            (Some(g), None) => {
                defs += &format!(
                    r#"<linearGradient id="g{i}" x1="{}" y1="{}" x2="{}" y2="{}" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="{}"/><stop offset="1" stop-color="{}"/></linearGradient>"#,
                    num(&g["from"][0]), num(&g["from"][1]), num(&g["to"][0]), num(&g["to"][1]),
                    g["stops"][0].as_str().unwrap(), g["stops"][1].as_str().unwrap()
                );
                a += &format!(r#" fill="url(#g{i})""#);
            }
            _ => a += &format!(r#" fill="{}""#, tint.or(l.get("fill").and_then(Value::as_str)).unwrap_or("#000000")),
        }
        if let (Some(o), None) = (l.get("opacity"), tint) {
            a += &format!(r#" fill-opacity="{}""#, num(o));
        }
        if l.get("evenodd").and_then(Value::as_bool) == Some(true) {
            a += r#" fill-rule="evenodd""#;
        }
        if let Some(r) = l.get("rotate").and_then(Value::as_array) {
            a += &format!(r#" transform="rotate({} {} {})""#, num(&r[0]), num(&r[1]), num(&r[2]));
        }
        inner += &format!("<path {a}/>");
    }
    body += &if tile.is_some() { format!(r#"<g clip-path="url(#c)">{inner}</g>"#) } else { inner };
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!-- {note} — shared/icon.json 에서 만든 파일(손으로 고치지 말 것, linux/dropcap-core/tests/icon_svg_tests.rs) -->\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{px}\" height=\"{px}\" viewBox=\"0 0 {unit} {unit}\">{}{body}</svg>\n",
        if defs.is_empty() { String::new() } else { format!("<defs>{defs}</defs>") }
    )
}

#[test]
fn linux_icons_match_shared_icon_json() {
    let doc: Value = serde_json::from_str(&std::fs::read_to_string(root().join("../shared/icon.json")).unwrap()).unwrap();
    let sym = &doc["symbol"];
    let su = sym["size"].as_f64().unwrap() as u32;
    let small = doc["smallMax"].as_u64().unwrap() as u32;
    // 상징 아이콘은 테마가 색을 바꾸므로 회색(#bebebe, 상징 아이콘 관례)으로 둔다
    let files = [
        ("resources/icons/io.github.dechsky.Dropcap.svg", svg(&doc["app"], &doc["app"]["layers"], 1024, 1024, None, "Dropcap 앱 아이콘(매거진 표지)")),
        ("resources/icons/small/io.github.dechsky.Dropcap.svg", svg(&doc["small"], &doc["small"]["layers"], small, 1024, None, "Dropcap 앱 아이콘 작은 크기(32px 이하) 단순화 판")),
        ("resources/icons/dropcap-newspaper-symbolic.svg", svg(sym, &sym["read"], su, su, Some("#bebebe"), "트레이 상징: 평소")),
        ("resources/icons/dropcap-newspaper-filled-symbolic.svg", svg(sym, &sym["unread"], su, su, Some("#bebebe"), "트레이 상징: 새 소식")),
    ];
    let update = std::env::var("DROPCAP_ICON_UPDATE").is_ok();
    for (path, want) in files {
        let p = root().join(path);
        if update {
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(&p, &want).unwrap();
        }
        let have = std::fs::read_to_string(&p).unwrap_or_default();
        assert_eq!(have, want, "{path} 가 shared/icon.json 과 다름 — DROPCAP_ICON_UPDATE=1 로 다시 만드세요");
    }
}
