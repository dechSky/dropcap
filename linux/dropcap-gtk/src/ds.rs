// 디자인 시스템 토큰(docs/DESIGN.md · 맥 UI/DesignSystem.swift 와 같은 값)

// 간격(4 배수)
#[allow(dead_code)]
pub mod space {
    pub const XXS: i32 = 2;
    pub const XS: i32 = 4;
    pub const S: i32 = 8;
    pub const M: i32 = 12;
    pub const L: i32 = 16;
    pub const XL: i32 = 24;
    pub const XXL: i32 = 32;
    pub const XXXL: i32 = 40;
    pub const PAGE: i32 = 36; // 매거진 지면 좌우 여백
}

// 글자 역할(크기, 굵기) — widgets::label 등에 그대로 넘긴다
#[allow(dead_code)]
pub mod font {
    pub const HERO: (f64, u16) = (38.0, 700); // '오늘' 지면 머리
    pub const TITLE: (f64, u16) = (32.0, 700); // 지면 제목·표지 기사
    pub const HEADING: (f64, u16) = (20.0, 600); // 지면 안 묶음 제목·빈 화면 제목
    pub const SUBHEADING: (f64, u16) = (16.0, 600);
    pub const HEADLINE: (f64, u16) = (15.0, 600); // 카드 제목·창 안 머리
    pub const BODY: (f64, u16) = (13.0, 400); // 화면 본문(읽기 창 본문은 설정 값)
    pub const BODY_STRONG: (f64, u16) = (13.0, 600);
    pub const CALLOUT: (f64, u16) = (12.0, 400); // 요약·설명 줄
    pub const CAPTION: (f64, u16) = (11.0, 400); // 출처·시간
    pub const CHIP: (f64, u16) = (11.0, 600); // 칩·배지·작은 단추
    pub const MICRO: (f64, u16) = (9.5, 600); // 건수·발행 중
}
