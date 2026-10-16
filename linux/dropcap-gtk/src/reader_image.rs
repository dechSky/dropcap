// 기사 속 사진 다루기(맥 Reader/ImageTools.swift): 사진 속 글자 번역 · 복사 · 저장.
// 사진에 마우스를 올리면 오른쪽 위에 작은 단추가 뜨고, 오른쪽 클릭 메뉴에도 같은 기능이 있다.
// 글자 읽기는 맥 Vision 대신 tesseract(있을 때, dropcap_core::image_text). 없으면 번역 창 아래 막대에 설치 안내.
use crate::app::{bg, copy_text};
use crate::widgets::load_texture;
use crate::{motion, theme};
use adw::prelude::*;
use dropcap_core::image_text::{self, Line, OcrError, Stage};
use gtk::{gdk, gio, glib, pango};
use std::cell::{Cell, RefCell};
use std::rc::Rc;

fn style(w: &impl IsA<gtk::Widget>, css: &str) {
    let p = gtk::CssProvider::new();
    p.load_from_string(&format!("* {{ {css} }}"));
    #[allow(deprecated)]
    w.as_ref().style_context().add_provider(&p, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
}

// 기사 속 사진(안전 로더, 원래 비율, R-18) + 사진 도구(R-20). 불러오는 동안 옅은 상자, 못 받으면 숨김.
pub fn article_image(url: &str) -> gtk::Widget {
    let stack = gtk::Stack::new();
    stack.set_margin_top(6);
    stack.set_margin_bottom(18);
    stack.set_transition_type(gtk::StackTransitionType::Crossfade);
    stack.set_transition_duration(if motion::enabled() { motion::SLOW } else { 0 });
    let ph = gtk::Box::new(gtk::Orientation::Vertical, 0);
    ph.set_height_request(180);
    style(&ph, "border-radius: 12px; background-color: alpha(@window_fg_color, 0.05);");
    let spin = gtk::Spinner::new();
    spin.start();
    spin.set_vexpand(true);
    spin.set_valign(gtk::Align::Center);
    ph.append(&spin);
    stack.add_named(&ph, Some("wait"));
    let pic = gtk::Picture::new();
    pic.set_content_fit(gtk::ContentFit::Contain);
    pic.set_can_shrink(true);
    pic.set_overflow(gtk::Overflow::Hidden);
    style(&pic, "border-radius: 12px;");
    let frame = gtk::Overlay::new();
    frame.set_child(Some(&pic));
    stack.add_named(&frame, Some("img"));
    if url.is_empty() {
        stack.set_visible(false);
        return stack.upcast();
    }
    let s2 = stack.clone();
    let url_s = url.to_string();
    load_texture(url, move |tex| match tex {
        Some(t) => {
            // 원래 비율 유지: 너비에 맞추되 원본보다 키우지 않음
            pic.set_paintable(Some(&t));
            pic.set_size_request(-1, (t.height() as f64 * (660.0 / t.width().max(1) as f64).min(1.0)) as i32);
            // 작은 그림(기자 얼굴·아이콘)은 본래 폭까지만(맥 ImageFit — 작은 원형 기자 사진을 본문 폭으로 키우던 것)
            if let Some(w) = dropcap_core::article::image_fit::max_width(t.width(), t.height()) {
                pic.set_content_fit(gtk::ContentFit::ScaleDown);
                pic.set_size_request(w, t.height());
                frame.set_halign(gtk::Align::Start);
            }
            attach_tools(&frame, &t, &url_s, "");
            s2.set_visible_child_name("img");
        }
        None => s2.set_visible(false),
    });
    stack.upcast()
}

fn tool(icon: &str, tip: &str) -> gtk::Button {
    let b = gtk::Button::builder().icon_name(icon).tooltip_text(tip).build();
    b.add_css_class("osd");
    b.set_size_request(28, 26);
    style(&b, "border-radius: 8px; min-height: 0; padding: 4px 6px;");
    b
}

// 마우스를 올리면 나오는 단추와 오른쪽 클릭 메뉴
pub fn attach_tools(frame: &gtk::Overlay, tex: &gdk::Texture, url: &str, title: &str) {
    let bar = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    bar.set_halign(gtk::Align::End);
    bar.set_valign(gtk::Align::Start);
    bar.set_margin_top(8);
    bar.set_margin_end(8);
    let tr = tool("preferences-desktop-locale-symbolic", "사진 속 글자 번역");
    let cp = tool("edit-copy-symbolic", "사진 복사");
    let sv = tool("document-save-symbolic", "사진 저장…");
    for b in [&tr, &cp, &sv] {
        bar.append(b);
    }
    bar.set_opacity(0.0);
    bar.set_can_target(false);
    frame.add_overlay(&bar);
    {
        let (t, u, ti) = (tex.clone(), url.to_string(), title.to_string());
        tr.connect_clicked(move |_| open_translate(&t, &u, &ti));
    }
    {
        let t = tex.clone();
        cp.connect_clicked(move |_| copy_image(&t));
    }
    {
        let (t, u) = (tex.clone(), url.to_string());
        sv.connect_clicked(move |b| save_image(b.upcast_ref(), &t, &u));
    }
    let hover = gtk::EventControllerMotion::new();
    {
        let bar = bar.clone();
        hover.connect_enter(move |_, _, _| {
            bar.set_can_target(true);
            fade(&bar, 1.0);
        });
    }
    {
        let bar = bar.clone();
        hover.connect_leave(move |_| {
            bar.set_can_target(false);
            fade(&bar, 0.0);
        });
    }
    frame.add_controller(hover);
    // 오른쪽 클릭 메뉴(맥 contextMenu)
    let click = gtk::GestureClick::builder().button(gdk::BUTTON_SECONDARY).build();
    let (t, u, ti, f) = (tex.clone(), url.to_string(), title.to_string(), frame.clone());
    click.connect_pressed(move |g, _, x, y| {
        g.set_state(gtk::EventSequenceState::Claimed);
        menu(&f, x, y, &t, &u, &ti);
    });
    frame.add_controller(click);
}

// 0.15초 동안 옅어지거나 또렷해진다(움직임 줄이기면 바로)
fn fade(w: &gtk::Box, to: f64) {
    if !motion::enabled() {
        w.set_opacity(to);
        return;
    }
    let target = adw::CallbackAnimationTarget::new({
        let w = w.clone();
        move |v| w.set_opacity(v)
    });
    let a = adw::TimedAnimation::new(w, w.opacity(), to, motion::QUICK, target);
    a.set_easing(if to < w.opacity() { motion::EXIT } else { motion::ENTER });
    a.play();
}

fn menu(frame: &gtk::Overlay, x: f64, y: f64, tex: &gdk::Texture, url: &str, title: &str) {
    let pop = gtk::Popover::new();
    pop.set_has_arrow(false);
    pop.set_parent(frame);
    pop.set_pointing_to(Some(&gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
    let v = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let item = |label: &str| {
        let b = gtk::Button::builder().label(label).css_classes(["flat"]).build();
        if let Some(l) = b.child().and_downcast::<gtk::Label>() {
            l.set_xalign(0.0);
        }
        v.append(&b);
        b
    };
    let tr = item("사진 속 글자 번역");
    v.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
    let cp = item("사진 복사");
    let sv = item("사진 저장…");
    let cu = item("사진 주소 복사");
    pop.set_child(Some(&v));
    {
        let (p, t, u, ti) = (pop.clone(), tex.clone(), url.to_string(), title.to_string());
        tr.connect_clicked(move |_| {
            p.popdown();
            open_translate(&t, &u, &ti);
        });
    }
    {
        let (p, t) = (pop.clone(), tex.clone());
        cp.connect_clicked(move |_| {
            p.popdown();
            copy_image(&t);
        });
    }
    {
        let (p, t, u, f) = (pop.clone(), tex.clone(), url.to_string(), frame.clone());
        sv.connect_clicked(move |_| {
            p.popdown();
            save_image(f.upcast_ref(), &t, &u);
        });
    }
    {
        let (p, u) = (pop.clone(), url.to_string());
        cu.connect_clicked(move |_| {
            p.popdown();
            copy_text(&u);
        });
    }
    pop.connect_closed(|p| {
        let p = p.clone();
        glib::idle_add_local_once(move || p.unparent());
    });
    pop.popup();
}

pub fn copy_image(tex: &gdk::Texture) {
    if let Some(d) = gdk::Display::default() {
        d.clipboard().set_texture(tex);
    }
}

// 저장(맥 NSSavePanel): 이름은 주소 마지막 조각.png, .jpg/.jpeg 로 고르면 앱이 담아 둔 JPEG 를 그대로
pub fn save_image(from: &gtk::Widget, tex: &gdk::Texture, url: &str) {
    let png = gtk::FileFilter::new();
    png.set_name(Some("PNG"));
    png.add_suffix("png");
    let jpg = gtk::FileFilter::new();
    jpg.set_name(Some("JPEG"));
    jpg.add_suffix("jpg");
    jpg.add_suffix("jpeg");
    let filters = gio::ListStore::new::<gtk::FileFilter>();
    filters.append(&png);
    filters.append(&jpg);
    let name = image_text::save_name(url);
    let dlg = gtk::FileDialog::builder().title("사진 저장").initial_name(name.as_str()).filters(&filters).modal(true).build();
    let parent = from.root().and_downcast::<gtk::Window>();
    let (tex, url) = (tex.clone(), url.to_string());
    dlg.save(parent.as_ref(), None::<&gio::Cancellable>, move |r| {
        let Ok(file) = r else { return };
        let Some(path) = file.path() else { return };
        let ext = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
        if ext == "jpg" || ext == "jpeg" {
            bg(
                async move {
                    if let Some(src) = dropcap_core::images::shared().image(&url).await {
                        let _ = std::fs::copy(src, &path);
                    }
                },
                |_| {},
            );
        } else {
            let _ = tex.save_to_png(&path);
        }
    });
}

// MARK: 사진 번역 창
struct Translate {
    lines: RefCell<Vec<Line>>,
    stage: Cell<Stage>,
    show_translation: Cell<bool>,
    status: gtk::Label,
    spin: gtk::Spinner,
    area: gtk::DrawingArea,
    list: gtk::Box,
    done_tools: gtk::Box,
}

pub fn open_translate(tex: &gdk::Texture, url: &str, title: &str) {
    let win = adw::Window::new();
    win.set_title(Some(&if title.is_empty() { "사진 번역".to_string() } else { format!("사진 번역 — {title}") }));
    let (iw, ih) = (tex.width().max(1) as f64, tex.height().max(1) as f64);
    let k = (900.0 / iw).min(640.0 / ih).min(1.0);
    win.set_default_size((iw * k + 40.0).max(560.0) as i32, (ih * k + 260.0).min(860.0) as i32);
    win.set_size_request(520, 420);

    let pic = gtk::Picture::for_paintable(tex);
    pic.set_content_fit(gtk::ContentFit::Contain);
    pic.set_can_shrink(true);
    pic.set_size_request(-1, (ih * k) as i32);
    let area = gtk::DrawingArea::new();
    area.set_can_target(false);
    let over = gtk::Overlay::new();
    over.set_child(Some(&pic));
    over.add_overlay(&area);
    over.set_overflow(gtk::Overflow::Hidden);
    style(&over, "border-radius: 10px;");
    let list = gtk::Box::new(gtk::Orientation::Vertical, 8);
    let col = gtk::Box::new(gtk::Orientation::Vertical, 16);
    for m in [&col] {
        m.set_margin_top(20);
        m.set_margin_bottom(20);
        m.set_margin_start(20);
        m.set_margin_end(20);
    }
    col.append(&over);
    col.append(&list);
    let scroll = gtk::ScrolledWindow::builder().child(&col).vexpand(true).hscrollbar_policy(gtk::PolicyType::Never).build();

    let bar = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    bar.set_margin_top(10);
    bar.set_margin_bottom(10);
    bar.set_margin_start(16);
    bar.set_margin_end(16);
    let spin = gtk::Spinner::new();
    let status = gtk::Label::new(None);
    status.set_wrap(true);
    status.set_xalign(0.0);
    status.set_hexpand(true);
    bar.append(&spin);
    bar.append(&status);
    let done_tools = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    done_tools.set_visible(false);
    let seg = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    seg.add_css_class("linked");
    let t_btn = gtk::ToggleButton::with_label("번역");
    let o_btn = gtk::ToggleButton::with_label("원본");
    o_btn.set_group(Some(&t_btn));
    t_btn.set_active(true);
    seg.append(&t_btn);
    seg.append(&o_btn);
    let copy_tr = gtk::Button::with_label("번역문 복사");
    done_tools.append(&seg);
    done_tools.append(&copy_tr);
    bar.append(&done_tools);
    let cp = gtk::Button::with_label("사진 복사");
    let sv = gtk::Button::with_label("저장…");
    bar.append(&cp);
    bar.append(&sv);
    style(&bar, "font-size: 12.5px;");

    let v = gtk::Box::new(gtk::Orientation::Vertical, 0);
    v.append(&adw::HeaderBar::new());
    v.append(&scroll);
    v.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
    v.append(&bar);
    win.set_content(Some(&v));

    let me = Rc::new(Translate {
        lines: RefCell::new(vec![]),
        stage: Cell::new(Stage::Reading),
        show_translation: Cell::new(true),
        status,
        spin,
        area: area.clone(),
        list,
        done_tools,
    });
    {
        let me2 = Rc::downgrade(&me);
        let (iw, ih) = (iw, ih);
        area.set_draw_func(move |_, cr, w, h| {
            if let Some(me) = me2.upgrade() {
                draw_overlay(&me, cr, w as f64, h as f64, iw, ih);
            }
        });
    }
    {
        let me = me.clone();
        t_btn.connect_toggled(move |b| {
            me.show_translation.set(b.is_active());
            me.area.queue_draw();
        });
    }
    {
        let me = me.clone();
        copy_tr.connect_clicked(move |_| {
            let text = me.lines.borrow().iter().map(|l| l.translated.clone().unwrap_or_else(|| l.text.clone())).collect::<Vec<_>>().join("\n");
            copy_text(&text);
        });
    }
    {
        let t = tex.clone();
        cp.connect_clicked(move |_| copy_image(&t));
    }
    {
        let (t, u) = (tex.clone(), url.to_string());
        sv.connect_clicked(move |b| save_image(b.upcast_ref(), &t, &u));
    }
    me.update();
    motion::present(&win);
    run(&me, url);
    // 닫으면 바로 놓아 사진째 메모리에 남지 않게(A-35)
    let keep = RefCell::new(Some(me));
    win.connect_close_request(move |w| {
        keep.borrow_mut().take();
        w.set_content(None::<&gtk::Widget>);
        glib::Propagation::Proceed
    });
}

// 읽기 → 외국어 줄만 번역(맥 ImageTranslateModel.run)
fn run(me: &Rc<Translate>, url: &str) {
    let url = url.to_string();
    let w = Rc::downgrade(me);
    bg(
        async move {
            let Some(path) = dropcap_core::images::shared().image(&url).await else { return Err(OcrError::Failed) };
            tokio::task::spawn_blocking(move || image_text::recognize(&path)).await.unwrap_or(Err(OcrError::Failed))
        },
        move |r| {
            let Some(me) = w.upgrade() else { return };
            let found = match r {
                Ok(l) => l,
                Err(OcrError::NoTesseract) => return me.set_stage(Stage::NoTool),
                Err(OcrError::Failed) => return me.set_stage(Stage::Failed),
            };
            *me.lines.borrow_mut() = found.clone();
            if found.is_empty() {
                return me.set_stage(Stage::NoText);
            }
            let foreign = image_text::foreign_lines(&found);
            if foreign.is_empty() {
                return me.set_stage(Stage::AlreadyKorean);
            }
            me.set_stage(Stage::Translating);
            let texts: Vec<String> = foreign.iter().map(|&i| found[i].text.clone()).collect();
            let w = Rc::downgrade(&me);
            bg(async move { dropcap_core::translator::SHARED.translate_many(&texts).await }, move |out| {
                let Some(me) = w.upgrade() else { return };
                {
                    let mut lines = me.lines.borrow_mut();
                    for (k, &i) in foreign.iter().enumerate() {
                        if let (Some(t), Some(l)) = (out.get(k), lines.get_mut(i)) {
                            l.translated = Some(t.clone());
                        }
                    }
                }
                me.set_stage(Stage::Done);
            });
        },
    );
}

impl Translate {
    fn set_stage(&self, s: Stage) {
        self.stage.set(s);
        self.update();
    }

    fn update(&self) {
        let s = self.stage.get();
        let n = self.lines.borrow().iter().filter(|l| l.translated.is_some()).count();
        self.status.set_text(&image_text::stage_text(s, n));
        let busy = matches!(s, Stage::Reading | Stage::Translating);
        self.spin.set_visible(busy);
        self.spin.set_spinning(busy);
        self.done_tools.set_visible(s == Stage::Done);
        // 읽은 글자 목록: 번역(있으면) 위, 원문 아래 작게
        while let Some(c) = self.list.first_child() {
            self.list.remove(&c);
        }
        let lines = self.lines.borrow();
        if !lines.is_empty() {
            let h = gtk::Label::new(Some("읽은 글자"));
            h.set_xalign(0.0);
            h.add_css_class("dc-secondary");
            style(&h, "font-size: 13px; font-weight: 600;");
            self.list.append(&h);
            for l in lines.iter() {
                let b = gtk::Box::new(gtk::Orientation::Vertical, 2);
                let main = gtk::Label::new(Some(l.translated.as_deref().unwrap_or(&l.text)));
                main.set_xalign(0.0);
                main.set_wrap(true);
                main.set_selectable(true);
                style(&main, "font-size: 14px;");
                b.append(&main);
                if l.translated.is_some() {
                    let o = gtk::Label::new(Some(&l.text));
                    o.set_xalign(0.0);
                    o.set_wrap(true);
                    o.set_selectable(true);
                    o.add_css_class("dc-secondary");
                    style(&o, "font-size: 12px;");
                    b.append(&o);
                }
                self.list.append(&b);
            }
        }
        self.area.queue_draw();
    }
}

// 원래 글자 자리를 사진 색으로 덮고 그 위에 번역문(상자에 맞춰 글자 크기를 줄임, 맥 overlayText)
fn draw_overlay(me: &Translate, cr: &gtk::cairo::Context, w: f64, h: f64, iw: f64, ih: f64) {
    if !me.show_translation.get() {
        return;
    }
    // Picture(ContentFit::Contain)와 같은 자리: 가운데에 비율대로
    let k = (w / iw).min(h / ih);
    let (dw, dh) = (iw * k, ih * k);
    let (ox, oy) = ((w - dw) / 2.0, (h - dh) / 2.0);
    for l in me.lines.borrow().iter() {
        let Some(t) = &l.translated else { continue };
        let (x, y, rw, rh) = (ox + l.x * dw, oy + l.y * dh, l.w * dw, l.h * dh);
        let (r, g, b) = l.background;
        cr.set_source_rgb(r as f64 / 255.0, g as f64 / 255.0, b as f64 / 255.0);
        rounded(cr, x - 2.0, y - 2.0, rw + 6.0, rh + 4.0, 3.0);
        let _ = cr.fill();
        let layout = pangocairo::functions::create_layout(cr);
        let mut size = (rh * 0.78).max(9.0);
        layout.set_width(((rw + 2.0) * pango::SCALE as f64) as i32);
        layout.set_ellipsize(pango::EllipsizeMode::End);
        layout.set_text(t);
        // 상자에 들어갈 때까지 줄인다(맥 minimumScaleFactor 0.3, 두 줄까지)
        let min = (size * 0.3).max(6.0);
        loop {
            let d = theme::font(size, pango::Weight::Semibold);
            layout.set_font_description(Some(&d));
            layout.set_wrap(pango::WrapMode::WordChar);
            layout.set_height(-2);
            let (lw, lh) = layout.pixel_size();
            if (lw as f64 <= rw + 2.0 && lh as f64 <= rh + 4.0) || size <= min {
                break;
            }
            size = (size * 0.9).max(min);
        }
        let (_, lh) = layout.pixel_size();
        let dark = image_text::dark_text_on(l.background);
        let c = if dark { 0.0 } else { 1.0 };
        cr.set_source_rgb(c, c, c);
        cr.move_to(x + 1.0, y + (rh - lh as f64) / 2.0);
        pangocairo::functions::show_layout(cr, &layout);
    }
}

fn rounded(cr: &gtk::cairo::Context, x: f64, y: f64, w: f64, h: f64, r: f64) {
    use std::f64::consts::PI;
    cr.new_sub_path();
    cr.arc(x + w - r, y + r, r, -PI / 2.0, 0.0);
    cr.arc(x + w - r, y + h - r, r, 0.0, PI / 2.0);
    cr.arc(x + r, y + h - r, r, PI / 2.0, PI);
    cr.arc(x + r, y + r, r, PI, 1.5 * PI);
    cr.close_path();
}
