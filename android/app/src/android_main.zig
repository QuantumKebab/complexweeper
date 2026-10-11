//! 复扫雷 Android 版
//!   规则层 game.zig 与素材 assets.zig / sounds.zig 原样复用仓库里的文件；
//!   这里做两件事：① 把 Win32 版的布局与绘制搬到软件帧缓冲（见 paint）；
//!   ② 用触摸手势 + 原生覆盖层界面替代 Windows 的菜单与对话框。
const std = @import("std");
const g = @import("game.zig");
const A = @import("assets.zig");
const U = @import("ui_assets.zig");
const snd = @import("sounds.zig");
const fb = @import("softfb.zig");
const plat = @import("platform.zig");

const APP_VERSION = "1.2.0";
/// 供规则自检（selftest.zig）抬头使用，与原版 main.zig 的约定一致
pub const testAppVersion = APP_VERSION;

// 菜单命令：编号与 Windows 版一致，行为一一对应（见 handleCommand）
const IDM_NEW: i32 = 100;
const IDM_BEGINNER: i32 = 101;
const IDM_INTERMEDIATE: i32 = 102;
const IDM_EXPERT: i32 = 103;
const IDM_CUSTOM: i32 = 104;
const IDM_BEST: i32 = 106;
const IDM_SOUND: i32 = 107;
const IDM_ZOOM_AUTO: i32 = 110;
const IDM_ZOOM1: i32 = 111;
const IDM_ZOOM2: i32 = 112;
const IDM_ZOOM3: i32 = 113;
const IDM_ZOOM4: i32 = 114;
const IDM_HYPER_BEGINNER: i32 = 120;
const IDM_HYPER_INTERMEDIATE: i32 = 121;
const IDM_HYPER_EXPERT: i32 = 122;
const IDM_HYPER_CUSTOM: i32 = 123;
const IDM_HYPER_BEST: i32 = 124;
const IDM_HELP_HOW: i32 = 200;
const IDM_HELP_ABOUT: i32 = 202;

const C_BTNFACE = fb.color(0xC0, 0xC0, 0xC0);
const C_HILIGHT = fb.color(0xDF, 0xDF, 0xDF);
const C_SHADOW = fb.color(0x80, 0x80, 0x80);
const C_BLACK = fb.color(0, 0, 0);
const C_WHITE = fb.color(0xFF, 0xFF, 0xFF);
const C_TITLE = fb.color(0x00, 0x00, 0x80);
const C_SCRIM = fb.colorA(0, 0, 0, 0x66);
const C_BAR = fb.color(0xC0, 0xC0, 0xC0);
const C_DROP = fb.color(0x40, 0x40, 0x40); // 面板投影
/// 纹理边长上限：GLES2 只保证 MAX_TEXTURE_SIZE ≥ 2048，客户区与界面图集都要守这个数
const TEX_MAX: i32 = 2048;

// ------------------------------------------------------------------ 全局状态
var game: g.Game = .{};
var zoom: i32 = 2; // 内部渲染倍率：按目标格子像素自动选，放大后依然清晰（只缩不放）
/// 用户可见的画面放大倍数：1.0 = 适应屏幕；>1 时画面超出屏幕，用单指拖动平移
var view_mag: f32 = 1.0;
var view_x: f32 = 0;
var view_y: f32 = 0;
var view_ready: bool = false;
var pan_mode: bool = false;
var last_move_x: f32 = 0;
var cur_preset: i32 = -1;

var screen_w: f32 = 0;
var screen_h: f32 = 0;
var text_h: f32 = 32;
var top_h: f32 = 60;
var hint_h: f32 = 40;

var game_scale: f32 = 1;
var game_x: f32 = 0;
var game_y: f32 = 0;
var game_dw: f32 = 0;
var game_dh: f32 = 0;

var fb_buf: []u32 = &.{};
var fb_w: i32 = 0;
var fb_h: i32 = 0;
var dirty: bool = true;

var face_down = false;
var face_armed = false;
var face_flash_until: u32 = 0;
const FACE_FLASH_MS: u32 = 200;
var press_cell: i32 = -1;
var chord_cell: i32 = -1;

var flag_mode = false;
var sound_off = false;
var sound_log: [snd.count]u32 = [_]u32{0} ** snd.count;
var over_sound_done = false;
var tick_second: i32 = -1;
var best_scores = [3]i32{ 0, 0, 0 };
var started_at: u32 = 0;

fn hyper() bool {
    return game.mode == .hyper;
}
fn nowMs() u32 {
    return plat.nowMs();
}

// ------------------------------------------------------------------ 布局（与 Windows 版一致）
pub const Layout = struct {
    z: i32,
    frame: i32,
    pad: i32,
    header_h: i32,
    gap: i32,
    box: i32,
    inner_w: i32,
    client_w: i32,
    client_h: i32,
    board_x: i32,
    board_y: i32,
    cell: i32,
    header_x: i32,
    header_y: i32,
    header_w: i32,
};

const REAL_DIGITS: i32 = 4;
const IMAG_DIGITS: i32 = 3;

fn valueDigits(base: i32, v: ?i32) i32 {
    if (v == null) return base;
    const x = v.?;
    if (x >= 0) return if (x <= pow10i(base) - 1) base else base + 1;
    return if (x >= -(pow10i(base - 1) - 1)) base else base + 1;
}
fn panelValueDigits(imag: bool, v: ?i32) i32 {
    return valueDigits(if (imag) IMAG_DIGITS else REAL_DIGITS, v);
}
fn panelCells(imag: bool, v: ?i32) i32 {
    return panelValueDigits(imag, v) + (if (imag) @as(i32, 1) else 0);
}
fn counterWidth(z: i32, digits: i32) i32 {
    return 16 * z + 2 * z + digits * 13 * z + 2 * z;
}
fn counterValue(t: usize) i32 {
    const k = game.unmarked(t);
    return switch (t) {
        2, 4 => -k,
        else => k,
    };
}
fn counterShown(t: usize) ?i32 {
    if (!game.started) return null;
    return counterValue(t);
}
fn counterImag(t: usize) bool {
    return t == 3 or t == 4;
}
fn countersWidth(L: Layout) i32 {
    var widest: i32 = 0;
    for (1..5) |t| {
        widest = @max(widest, counterWidth(L.z, panelCells(counterImag(t), counterShown(t))));
    }
    return widest;
}
fn timerWidth(z: i32) i32 {
    return 4 * 13 * z + 2 * z;
}
fn headerContentWidth(z: i32) i32 {
    const col = counterWidth(z, 4);
    return 4 * z + col + 8 * z + FACE_SIZE * z + 8 * z + timerWidth(z) + 4 * z;
}

fn layout() Layout {
    const z = zoom;
    const frame = 3 * z;
    const pad = 6 * z;
    const gap = 6 * z;
    const box = 3 * z;
    const cell = 16 * z;
    const board_w = @as(i32, game.w) * cell + 2 * box;
    const hw = headerContentWidth(z);
    const inner_w = @max(board_w, hw);
    const client_w = inner_w + 2 * (frame + pad);
    const counters_h = 4 * (26 * z) + 3 * (2 * z);
    const header_h = 2 * (2 * z) + 2 * (3 * z) + counters_h;
    const client_h = 2 * (frame + pad) + header_h + gap + @as(i32, game.h) * cell + 2 * box;
    return .{
        .z = z,
        .frame = frame,
        .pad = pad,
        .header_h = header_h,
        .gap = gap,
        .box = box,
        .inner_w = inner_w,
        .client_w = client_w,
        .client_h = client_h,
        .board_x = frame + pad + @divTrunc(inner_w - board_w, 2) + box,
        .board_y = frame + pad + header_h + gap + box,
        .cell = cell,
        .header_x = frame + pad,
        .header_y = frame + pad,
        .header_w = inner_w,
    };
}

fn countersX(L: Layout) i32 {
    return L.header_x + 4 * L.z;
}
fn countersY(L: Layout) i32 {
    return L.header_y + 2 * L.z + 3 * L.z;
}
const FACE_SIZE: i32 = 24;
const FACE_NUDGE: i32 = 2;

fn faceLeft(L: Layout) i32 {
    const size = FACE_SIZE * L.z;
    const counters_end = countersX(L) + countersWidth(L);
    const timer_start = timerX(L);
    const clearance = 6 * L.z;
    var fx = L.header_x + @divTrunc(L.header_w, 2) - @divTrunc(size, 2);
    if (fx < counters_end + clearance) fx = counters_end + clearance;
    if (fx + size > timer_start - clearance) fx = timer_start - clearance - size;
    if (fx < L.header_x) fx = L.header_x;
    return fx - FACE_NUDGE;
}
fn faceTop(L: Layout) i32 {
    return L.header_y + @divTrunc(L.header_h - FACE_SIZE * L.z, 2) - FACE_NUDGE;
}
fn timerX(L: Layout) i32 {
    return L.header_x + L.header_w - 4 * L.z - timerWidth(L.z);
}
fn timerY(L: Layout) i32 {
    return L.header_y + @divTrunc(L.header_h - 26 * L.z, 2);
}

fn pow10i(n: i32) i32 {
    var r: i32 = 1;
    var i: i32 = 0;
    while (i < n) : (i += 1) r *= 10;
    return r;
}
fn fmtDigits(buf: []u8, v: u32, digits: u32) usize {
    var i: usize = digits;
    var x = v;
    while (i > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (x % 10));
        x /= 10;
    }
    return digits;
}
fn digitSprite(ch: u8) u16 {
    return switch (ch) {
        '0' => A.led_0,
        '1' => A.led_1,
        '2' => A.led_2,
        '3' => A.led_3,
        '4' => A.led_4,
        '5' => A.led_5,
        '6' => A.led_6,
        '7' => A.led_7,
        '8' => A.led_8,
        else => A.led_9,
    };
}

// ------------------------------------------------------------------ 绘制
fn blitSprite(sprite: u16, x: i32, y: i32, dw: i32, dh: i32) void {
    fb.blit(sprite, x, y, dw, dh);
}
fn blitSpriteSq(sprite: u16, x: i32, y: i32, size: i32) void {
    fb.blit(sprite, x, y, size, size);
}
fn drawLed(x: i32, y: i32, v: ?i32, digits: i32, z: i32) i32 {
    const lw = 13 * z;
    const lh = 23 * z;
    var cx = x;
    if (v == null) {
        var i: i32 = 0;
        while (i < digits) : (i += 1) {
            blitSprite(A.led_blank, cx, y, lw, lh);
            cx += lw;
        }
        return cx - x;
    }
    const val = v.?;
    if (val < 0) {
        blitSprite(A.led_minus, cx, y, lw, lh);
        cx += lw;
        var m = -val;
        const lim = pow10i(digits - 1) - 1;
        if (m > lim) m = lim;
        var buf: [4]u8 = undefined;
        const n = fmtDigits(&buf, @intCast(m), @intCast(digits - 1));
        for (buf[0..n]) |ch| {
            blitSprite(digitSprite(ch), cx, y, lw, lh);
            cx += lw;
        }
    } else {
        var m = val;
        const lim = pow10i(digits) - 1;
        if (m > lim) m = lim;
        var buf: [4]u8 = undefined;
        const n = fmtDigits(&buf, @intCast(m), @intCast(digits));
        for (buf[0..n]) |ch| {
            blitSprite(digitSprite(ch), cx, y, lw, lh);
            cx += lw;
        }
    }
    return cx - x;
}

fn mineSprite(t: u8) u16 {
    return (if (hyper()) A.hmine_T else A.mine_T)[@min(@as(usize, t), 4)];
}
fn flagSprite(t: u8) u16 {
    return (if (hyper()) A.hflag_T else A.flag_T)[@min(@as(usize, t), 4)];
}
fn boomSprite(t: u8) u16 {
    return (if (hyper()) A.hboom_T else A.boom_T)[@min(@as(usize, t), 4)];
}
fn wrongSprite(t: u8) u16 {
    return (if (hyper()) A.hwrong_T else A.wrong_T)[@min(@as(usize, t), 4)];
}
fn rightSprite(t: u8) u16 {
    return (if (hyper()) A.hright_T else A.right_T)[@min(@as(usize, t), 4)];
}
fn rightFlagSprite(t: u8) u16 {
    return (if (hyper()) A.hrightflag_T else A.rightflag_T)[@min(@as(usize, t), 4)];
}
fn wrongFlagSprite(t: u8) u16 {
    return (if (hyper()) A.hwrongflag_T else A.wrongflag_T)[@min(@as(usize, t), 4)];
}

fn chordable(c: usize) bool {
    if (c >= game.n) return false;
    if (game.over or game.open[c] == 0 or game.mine[c] != 0) return false;
    var buf: [8]usize = undefined;
    const k = game.nbrs(c, &buf);
    for (buf[0..k]) |j| {
        if (game.open[j] == 0 and game.flag[j] == 0) return true;
    }
    return false;
}
fn chordTarget(i: usize) bool {
    if (chord_cell < 0) return false;
    const c: usize = @intCast(chord_cell);
    if (!chordable(c)) return false;
    if (game.open[i] != 0 or game.flag[i] != 0) return false;
    var buf: [8]usize = undefined;
    const k = game.nbrs(c, &buf);
    for (buf[0..k]) |j| {
        if (j == i) return true;
    }
    return false;
}
fn cellSprite(i: usize) u16 {
    if (press_cell >= 0 and @as(usize, @intCast(press_cell)) == i and game.open[i] == 0) return A.blank;
    if (chordTarget(i)) return A.blank;
    const revealed = game.over and !game.win;
    if (game.open[i] != 0) {
        if (game.mine[i] != 0) {
            if (game.boom == @as(i32, @intCast(i))) return boomSprite(game.mine[i]);
            return mineSprite(game.mine[i]);
        }
        const D = game.clue[i];
        if (D == 0 and game.nbrMineCount(i) == 0) return A.blank;
        const s = if (hyper())
            A.hnum_by_D[@intCast(D + 64)]
        else
            A.num_by_D[@intCast(D)];
        return if (s == 0xFFFF) A.blank else s;
    }
    if (game.flag[i] != 0) {
        const t = game.mine[i];
        const f = game.flag[i];
        if (revealed) {
            if (t == 0) return A.wrongblank_sprite;
            if (f == t) return rightSprite(t);
            return wrongSprite(t);
        }
        if (game.win) {
            if (t != 0 and f == t) return rightFlagSprite(t);
            return wrongFlagSprite(if (t != 0) t else f);
        }
        return flagSprite(f);
    }
    if (revealed and game.mine[i] != 0) return mineSprite(game.mine[i]);
    return A.closed;
}

fn faceSprite() u16 {
    if (face_down) return A.face_down;
    if (game.over) return if (game.win) A.face_win else A.face_dead;
    if (press_cell >= 0 or chord_cell >= 0) return A.face_scan;
    if (nowMs() < face_flash_until) return A.face_scan;
    return A.face_normal;
}

fn timerSeconds() i32 {
    if (!game.started) return 0;
    return @intCast(@min(@as(u32, 9999), game.elapsed_ms / 1000));
}

/// 棋盘绘制：与 Windows 版 paint() 逐句对应，只是把 HDC 换成软件帧缓冲
fn paint(L: Layout) void {
    fb.fill(0, 0, L.client_w, L.client_h, C_BTNFACE);
    fb.draw3d(0, 0, L.client_w, L.client_h, L.frame, true, C_HILIGHT, C_SHADOW);

    const hx = L.header_x;
    const hy = L.header_y;
    const hh = L.header_h;
    const hw2 = L.header_w;
    fb.draw3d(hx, hy, hw2, hh, 2 * L.z, false, C_HILIGHT, C_SHADOW);

    const col_x = countersX(L);
    var cy = countersY(L);
    for (1..5) |t| {
        const val = counterShown(t);
        const imag = counterImag(t);
        const cw2 = counterWidth(L.z, panelCells(imag, val));
        fb.draw3d(col_x, cy, cw2, 26 * L.z, 1 * L.z, false, C_HILIGHT, C_SHADOW);
        blitSpriteSq(flagSprite(@intCast(t)), col_x + L.z + L.z, cy + @divTrunc(26 * L.z - 16 * L.z, 2), 16 * L.z);
        const led_x = col_x + L.z + 2 * L.z + 16 * L.z;
        const led_y = cy + @divTrunc(26 * L.z - 23 * L.z, 2);
        const vw = drawLed(led_x, led_y, val, panelValueDigits(imag, val), L.z);
        if (imag) blitSprite(if (val == null) A.led_blank else if (hyper()) A.led_j else A.led_i, led_x + vw, led_y, 13 * L.z, 23 * L.z);
        cy += 26 * L.z + 2 * L.z;
    }

    const tx = timerX(L);
    const ty = timerY(L);
    const tv: ?i32 = if (game.started) timerSeconds() else null;
    fb.draw3d(tx, ty, timerWidth(L.z), 26 * L.z, 1 * L.z, false, C_HILIGHT, C_SHADOW);
    _ = drawLed(tx + L.z, ty + @divTrunc(26 * L.z - 23 * L.z, 2), tv, panelValueDigits(false, tv), L.z);

    blitSpriteSq(faceSprite(), faceLeft(L), faceTop(L), FACE_SIZE * L.z);

    const bx = L.board_x - L.box;
    const by = L.board_y - L.box;
    const bw = @as(i32, game.w) * L.cell + 2 * L.box;
    const bh = @as(i32, game.h) * L.cell + 2 * L.box;
    fb.draw3d(bx, by, bw, bh, L.box, false, C_HILIGHT, C_SHADOW);

    var i: usize = 0;
    while (i < game.n) : (i += 1) {
        const r: i32 = @intCast(i / game.w);
        const c: i32 = @intCast(i % game.w);
        blitSpriteSq(cellSprite(i), L.board_x + c * L.cell, L.board_y + r * L.cell, L.cell);
    }
}

// ------------------------------------------------------------------ 帧缓冲与重绘
fn ensureFb(L: Layout) void {
    if (fb_w == L.client_w and fb_h == L.client_h and fb_buf.len > 0) return;
    if (fb_buf.len > 0) plat.free(@ptrCast(fb_buf.ptr));
    const count: usize = @as(usize, @intCast(L.client_w)) * @as(usize, @intCast(L.client_h));
    const raw = plat.malloc(count * 4) orelse {
        plat.log("帧缓冲分配失败");
        fb_buf = &.{};
        fb_w = 0;
        fb_h = 0;
        return;
    };
    const p: [*]u32 = @ptrCast(@alignCast(raw));
    fb_buf = p[0..count];
    fb_w = L.client_w;
    fb_h = L.client_h;
    fb.setTarget(p, fb_w, fb_h);
}

fn repaint() void {
    const L = layout();
    ensureFb(L);
    if (fb_w == 0 or fb_h == 0) return;
    paint(L);
    plat.cs_set_fb(fb.bytes().ptr, fb_w, fb_h);
    dirty = false;
}

// ------------------------------------------------------------------ 局面操作
fn presetIndex() i32 {
    for (g.PRESETS, 0..) |p, i| {
        if (game.w == p.w and game.h == p.h and game.mines == p.mines) return @intCast(i);
    }
    return -1;
}

fn startNewGame(seed_override: ?u32) void {
    const seed = seed_override orelse nowMs();
    game.newGame(seed);
    press_cell = -1;
    chord_cell = -1;
    face_down = false;
    face_armed = false;
    face_flash_until = 0;
    over_sound_done = false;
    tick_second = -1;
    dirty = true;
}

fn setPreset(idx: i32, m: g.Mode) void {
    if (idx >= 0 and idx < g.PRESETS.len) {
        const p = g.PRESETS[@intCast(idx)];
        game.w = p.w;
        game.h = p.h;
        game.mines = p.mines;
        game.type_count = [_]u16{0} ** 5;
    }
    game.mode = m;
    cur_preset = idx;
    loadScores();
    startNewGame(null);
}

fn applyCustomFromDialog() void {
    cur_preset = -1;
    loadScores();
    startNewGame(null);
}

fn flashFace() void {
    face_flash_until = nowMs() +% FACE_FLASH_MS;
}

fn doExpand(c: usize) void {
    const m0 = game.moves;
    game.tryExpand(c);
    afterGameAction();
    if (game.moves != m0 and !game.over) flashFace();
    dirty = true;
}

fn afterGameAction() void {
    if (!game.over) return;
    if (!over_sound_done) {
        over_sound_done = true;
        if (game.win) {
            playSound(.win);
        } else {
            const t: u8 = if (game.boom >= 0) game.mine[@intCast(game.boom)] else 1;
            playSound(snd.Sounds.mineOf(t));
        }
    }
    if (game.t0 != 0) game.elapsed_ms = nowMs() -% game.t0;
    if (!game.win) return;
    const idx = presetIndex();
    if (idx < 0) return;
    const sec: i32 = @max(1, @as(i32, @intCast(game.elapsed_ms / 1000)));
    const u: usize = @intCast(idx);
    var set = if (game.mode == .hyper) &hyper_scores else &cplx_scores;
    if (set[u] != 0 and sec >= set[u]) return;
    set[u] = sec;
    savePrefs();
    showScores(true, game.mode);
}

/// 在某一格上"翻开"（左键的语义）
fn revealAt(c: usize) void {
    if (game.over or game.flag[c] != 0) return;
    const covered = game.open[c] == 0;
    if (!game.started) {
        game.startAt(c, nowMs());
        game.setMsg(.started);
        started_at = nowMs();
    } else {
        game.reveal(c, nowMs());
        afterGameAction();
    }
    if (covered and !game.over) flashFace();
    dirty = true;
}

// ------------------------------------------------------------------ 音效与存档
fn playSound(s: snd.Sounds) void {
    if (sound_off) return; // 静音时连计数也不记，自检据此确认开关真的拦住了播放
    const i = @intFromEnum(s);
    sound_log[i] +%= 1;
    plat.cs_play_sound(@intCast(i));
}

fn maybePlayTick() void {
    if (!game.started or game.over) return;
    const sec = timerSeconds();
    if (sec < 1 or sec == tick_second) return;
    tick_second = sec;
    playSound(.tick);
}

fn toggleSound() void {
    sound_off = !sound_off;
    if (sound_off) plat.cs_stop_audio();
    savePrefs();
    dirty = true;
}

var cplx_scores = [3]i32{ 0, 0, 0 };
var hyper_scores = [3]i32{ 0, 0, 0 };

fn loadScores() void {
    best_scores = if (game.mode == .hyper) hyper_scores else cplx_scores;
}

fn loadPrefs() void {
    var buf: [512]u8 = undefined;
    const n = plat.cs_read_file("complexsweeper.cfg", &buf, buf.len);
    if (n <= 0) return;
    var it = std.mem.tokenizeAny(u8, buf[0..@intCast(n)], " \r\n\t");
    while (it.next()) |key| {
        if (std.mem.eql(u8, key, "sound")) {
            if (it.next()) |v| sound_off = std.mem.eql(u8, v, "0");
        } else if (std.mem.eql(u8, key, "flagmode")) {
            if (it.next()) |v| flag_mode = std.mem.eql(u8, v, "1");
        } else if (std.mem.eql(u8, key, "cplx")) {
            for (0..3) |i| {
                if (it.next()) |v| cplx_scores[i] = std.fmt.parseInt(i32, v, 10) catch 0;
            }
        } else if (std.mem.eql(u8, key, "hyper")) {
            for (0..3) |i| {
                if (it.next()) |v| hyper_scores[i] = std.fmt.parseInt(i32, v, 10) catch 0;
            }
        }
    }
}

fn savePrefs() void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "sound {d}\nflagmode {d}\ncplx {d} {d} {d}\nhyper {d} {d} {d}\n", .{
        @as(u8, if (sound_off) 0 else 1),
        @as(u8, if (flag_mode) 1 else 0),
        cplx_scores[0], cplx_scores[1], cplx_scores[2],
        hyper_scores[0], hyper_scores[1], hyper_scores[2],
    }) catch return;
    _ = plat.cs_write_file("complexsweeper.cfg", s.ptr, @intCast(s.len));
}

// ------------------------------------------------------------------ 覆盖层界面
const Overlay = enum(u8) { none, menu, mode_cplx, mode_hyper, zoom, custom, scores, help, about };
var overlay: Overlay = .none;
var scores_mode: g.Mode = .complex;
var scores_highlight = false;
var help_scroll: f32 = 0;

var dlg_h: i32 = 16;
var dlg_w: i32 = 30;
var dlg_t: [5]i32 = .{ 0, 25, 25, 25, 24 };
const DlgErr = enum(u8) { none, height, width, sum_zero, sum_big };
var dlg_err: DlgErr = .none;

const ICM_SPLIT: i32 = 300;
const ICM_OK: i32 = 301;
const ICM_CANCEL: i32 = 302;

const Rect = struct { x: f32, y: f32, w: f32, h: f32 };
const Act = enum(u8) { command, submenu, stepper, close, none };
const Item = struct {
    r: Rect,
    label: u16,
    act: Act,
    arg: i32 = 0,
    delta: i32 = 0,
    dot: bool = false,
    active: bool = false,
    pressed: bool = false,
};
var items: [40]Item = undefined;
var item_count: usize = 0;
var item_pressed: i32 = -1;
var panel_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var panel_title: u16 = U.m_title;
var cu_rows: [6]Rect = undefined;
var cu_btns: [3]Rect = undefined;
/// 自定义面板每行「减号—数值—加号」之间的数值绘制区（由 buildItems 按面板几何算出）
var cu_val_x: f32 = 0;
var cu_val_w: f32 = 0;

fn textScaleFor(h: f32) f32 {
    return h / @as(f32, @floatFromInt(U.line_h));
}
fn drawTextAt(idx: u16, x: f32, y: f32, h: f32, color: u32) f32 {
    const r = U.rect(idx);
    const s = textScaleFor(h);
    const dw = @as(f32, @floatFromInt(r.w)) * s;
    plat.cs_draw_ui(@intCast(r.x), @intCast(r.y), @intCast(r.w), @intCast(r.h), x, y, dw, h, color);
    return dw;
}
fn textWidth(idx: u16, h: f32) f32 {
    const r = U.rect(idx);
    return @as(f32, @floatFromInt(r.w)) * textScaleFor(h);
}
fn drawSprite(idx: u16, x: f32, y: f32, dw: f32, dh: f32, color: u32) void {
    const r = U.rect(idx);
    plat.cs_draw_ui(@intCast(r.x), @intCast(r.y), @intCast(r.w), @intCast(r.h), x, y, dw, dh, color);
}
fn solid(x: f32, y: f32, w2: f32, h2: f32, color: u32) void {
    drawSprite(U.ui_white, x, y, w2, h2, color);
}
fn bevel(x: f32, y: f32, w2: f32, h2: f32, t: f32, raised: bool, face: u32) void {
    solid(x, y, w2, h2, face);
    const a = if (raised) C_WHITE else C_SHADOW;
    const b = if (raised) C_SHADOW else C_WHITE;
    solid(x, y, w2, t, a);
    solid(x, y, t, h2, a);
    solid(x, y + h2 - t, w2, t, b);
    solid(x + w2 - t, y, t, h2, b);
}
fn drawStr(str: []const u8, x: f32, y: f32, h: f32, color: u32) f32 {
    const s = textScaleFor(h);
    var cx = x;
    for (str) |ch| {
        if (ch < U.ch_first or ch > U.ch_last) continue;
        const i = U.ch_idx[ch - U.ch_first];
        const r = U.rect(i);
        plat.cs_draw_ui(@intCast(r.x), @intCast(r.y), @intCast(r.w), @intCast(r.h), cx, y, @as(f32, @floatFromInt(r.w)) * s, h, color);
        cx += @as(f32, @floatFromInt(U.ch_adv[ch - U.ch_first])) * s;
    }
    return cx - x;
}
fn drawInt(v: i32, x: f32, y: f32, h: f32, color: u32) f32 {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return 0;
    return drawStr(s, x, y, h, color);
}
fn strWidth(str: []const u8, h: f32) f32 {
    const s = textScaleFor(h);
    var wd: f32 = 0;
    for (str) |ch| {
        if (ch < U.ch_first or ch > U.ch_last) continue;
        wd += @as(f32, @floatFromInt(U.ch_adv[ch - U.ch_first])) * s;
    }
    return wd;
}

fn addItem(r: Rect, label: u16, act: Act, arg: i32, delta: i32) void {
    if (item_count >= items.len) return;
    items[item_count] = .{ .r = r, .label = label, .act = act, .arg = arg, .delta = delta };
    item_count += 1;
}
fn addItemFlags(r: Rect, label: u16, act: Act, arg: i32, dot: bool, active: bool) void {
    addItem(r, label, act, arg, 0);
    items[item_count - 1].dot = dot;
    items[item_count - 1].active = active;
}

fn panelGeom(rows: usize) void {
    const row_h = text_h * 1.9;
    const pw = @min(screen_w * 0.94, @max(text_h * 18.0, 280.0));
    const ph = text_h * 2.4 + @as(f32, @floatFromInt(rows)) * row_h + text_h * 0.6;
    panel_rect = .{ .x = (screen_w - pw) * 0.5, .y = (screen_h - ph) * 0.5, .w = pw, .h = ph };
}

fn listRows(count: usize, labels: []const u16, acts: []const Act, args: []const i32, dots: []const bool) void {
    panelGeom(count);
    const row_h = text_h * 1.9;
    var y = panel_rect.y + text_h * 2.2;
    const x = panel_rect.x + text_h * 0.7;
    const w2 = panel_rect.w - text_h * 1.4;
    for (0..count) |i| {
        addItemFlags(.{ .x = x, .y = y, .w = w2, .h = row_h * 0.92 }, labels[i], acts[i], args[i], if (i < dots.len) dots[i] else false, false);
        y += row_h;
    }
}

fn buildItems() void {
    item_count = 0;
    switch (overlay) {
        .none => {},
        .menu => {
            panel_title = U.m_title;
            const labels = [_]u16{ U.m_new, U.m_cplx, U.m_hyper, if (sound_off) U.m_sound_off else U.m_sound_on, U.m_zoom, U.m_help, U.m_about, U.m_close };
            const acts = [_]Act{ .command, .submenu, .submenu, .command, .submenu, .command, .command, .command };
            const args = [_]i32{ IDM_NEW, @intFromEnum(Overlay.mode_cplx), @intFromEnum(Overlay.mode_hyper), IDM_SOUND, @intFromEnum(Overlay.zoom), IDM_HELP_HOW, IDM_HELP_ABOUT, 0 };
            const dots = [_]bool{ false, false, false, !sound_off, false, false, false, false };
            listRows(8, &labels, &acts, &args, &dots);
        },
        .mode_cplx, .mode_hyper => {
            const is_hyper = overlay == .mode_hyper;
            panel_title = if (is_hyper) U.sm_title_hyper else U.sm_title_cplx;
            const labels = [_]u16{ U.sm_beg, U.sm_int, U.sm_exp, U.sm_custom, U.sm_best, U.sm_back };
            const acts = [_]Act{ .command, .command, .command, .command, .command, .submenu };
            const base: i32 = if (is_hyper) IDM_HYPER_BEGINNER else IDM_BEGINNER;
            const args = [_]i32{ base, base + 1, base + 2, base + 3, if (is_hyper) IDM_HYPER_BEST else IDM_BEST, @intFromEnum(Overlay.menu) };
            const p = presetIndex();
            const dots = [_]bool{ p == 0, p == 1, p == 2, false, false, false };
            listRows(6, &labels, &acts, &args, &dots);
        },
        .zoom => {
            panel_title = U.zm_title;
            const labels = [_]u16{ U.zm_auto, U.zm_150, U.zm_200, U.zm_300, U.zm_400, U.zm_back };
            const acts = [_]Act{ .command, .command, .command, .command, .command, .submenu };
            const args = [_]i32{ IDM_ZOOM_AUTO, IDM_ZOOM1, IDM_ZOOM2, IDM_ZOOM3, IDM_ZOOM4, @intFromEnum(Overlay.menu) };
            const dots = [_]bool{ view_mag <= 1.01, nearMag(1.5), nearMag(2.0), nearMag(3.0), nearMag(4.0), false };
            listRows(6, &labels, &acts, &args, &dots);
        },
        .custom => {
            panel_title = U.cu_title;
            const row_h2 = text_h * 1.75;
            const pw = @min(screen_w * 0.96, @max(text_h * 22.0, 300.0));
            const ph = text_h * 2.4 + row_h2 * 9.2;
            panel_rect = .{ .x = (screen_w - pw) * 0.5, .y = (screen_h - ph) * 0.5, .w = pw, .h = ph };
            var y = panel_rect.y + text_h * 2.2;
            const lx = panel_rect.x + text_h * 0.7;
            const bw = text_h * 2.0;
            const vw = text_h * 4.2;
            const rx = panel_rect.x + panel_rect.w - text_h * 0.7 - bw * 2 - vw - text_h * 0.4;
            cu_val_x = rx + bw;
            cu_val_w = vw + text_h * 0.2;
            for (0..6) |i| {
                cu_rows[i] = .{ .x = lx, .y = y, .w = panel_rect.w - text_h * 1.4, .h = row_h2 * 0.88 };
                addItem(.{ .x = rx, .y = y, .w = bw, .h = row_h2 * 0.88 }, 0xFFFF, .stepper, @intCast(i), -1);
                addItem(.{ .x = rx + bw + vw + text_h * 0.4, .y = y, .w = bw, .h = row_h2 * 0.88 }, 0xFFFF, .stepper, @intCast(i), 1);
                y += row_h2;
            }
            y += row_h2 * 0.15;
            cu_btns[0] = .{ .x = panel_rect.x + text_h * 0.7, .y = y, .w = panel_rect.w - text_h * 1.4, .h = row_h2 * 0.9 };
            addItem(cu_btns[0], U.cu_split, .command, ICM_SPLIT, 0);
            y += row_h2;
            const half = (panel_rect.w - text_h * 1.4 - text_h * 0.4) * 0.5;
            cu_btns[1] = .{ .x = panel_rect.x + text_h * 0.7, .y = y, .w = half, .h = row_h2 * 0.9 };
            cu_btns[2] = .{ .x = panel_rect.x + text_h * 0.7 + half + text_h * 0.4, .y = y, .w = half, .h = row_h2 * 0.9 };
            addItem(cu_btns[1], U.cu_ok, .command, ICM_OK, 0);
            addItem(cu_btns[2], U.cu_cancel, .command, ICM_CANCEL, 0);
        },
        .scores, .help, .about => {
            panel_title = switch (overlay) {
                .scores => if (scores_highlight)
                    (if (scores_mode == .hyper) U.sc_new_hyper else U.sc_new_cplx)
                else if (scores_mode == .hyper) U.sc_title_hyper else U.sc_title_cplx,
                .help => U.hp_title,
                else => U.ab_title,
            };
            const pw = @min(screen_w * 0.96, screen_w - text_h * 0.6);
            const ph = screen_h - top_h - hint_h - text_h * 1.2;
            panel_rect = .{ .x = (screen_w - pw) * 0.5, .y = top_h + text_h * 0.4, .w = pw, .h = ph };
            const bh = text_h * 2.0;
            const bw = @min(panel_rect.w * 0.5, text_h * 9.0);
            addItem(.{
                .x = panel_rect.x + (panel_rect.w - bw) * 0.5,
                .y = panel_rect.y + panel_rect.h - bh - text_h * 0.4,
                .w = bw,
                .h = bh * 0.85,
            }, switch (overlay) {
                .scores => U.sc_close,
                .help => U.hp_close,
                else => U.ab_close,
            }, .close, 0, 0);
        },
    }
}

// ------------------------------------------------------------------ 界面绘制
var tb_rects: [5]Rect = undefined;
var tb_pressed: i32 = -1;

fn layoutTopBar() void {
    const gap = text_h * 0.35;
    const w2 = (screen_w - gap * 6) / 5.0;
    const h2 = top_h - gap * 1.6;
    for (0..5) |i| {
        tb_rects[i] = .{ .x = gap + (w2 + gap) * @as(f32, @floatFromInt(i)), .y = gap * 0.8, .w = w2, .h = h2 };
    }
}

fn drawButton(r: Rect, label: u16, pressed: bool, active: bool) void {
    bevel(r.x, r.y, r.w, r.h, text_h * 0.12, !pressed, if (active) fb.color(0xD0, 0xD8, 0xE8) else C_BTNFACE);
    const lh = text_h * 0.9;
    const tw = textWidth(label, lh);
    _ = drawTextAt(label, r.x + (r.w - tw) * 0.5, r.y + (r.h - lh) * 0.5, lh, C_BLACK);
}

fn drawTopBar() void {
    solid(0, 0, screen_w, top_h, C_BAR);
    solid(0, top_h - 2, screen_w, 2, C_SHADOW);
    for (0..5) |i| {
        const active = (i == 1 and flag_mode) or (i == 0 and overlay != .none) or
            (i == 3 and view_mag <= 1.01) or (i == 4 and view_mag >= 3.99);
        const label: u16 = switch (i) {
            0 => U.tb_menu,
            1 => if (flag_mode) U.tb_flag else U.tb_open,
            2 => U.tb_restart,
            3 => U.tb_out,
            else => U.tb_in,
        };
        drawButton(tb_rects[i], label, tb_pressed == @as(i32, @intCast(i)), active);
    }
}

fn drawHint() void {
    const y = screen_h - hint_h;
    solid(0, y, screen_w, hint_h, C_BAR);
    solid(0, y, screen_w, 2, C_HILIGHT);
    const lbl: u16 = if (view_mag >= 3.99) U.hint_z4 else if (view_mag >= 2.99) U.hint_z3 else if (view_mag >= 1.99) U.hint_z2 else if (view_mag >= 1.49) U.hint_z1 else if (flag_mode) U.hint_flag else U.hint_open;
    var hh = text_h * 0.78;
    var tw = textWidth(lbl, hh);
    const avail = screen_w - text_h;
    if (tw > avail) {
        hh *= avail / tw;
        tw = avail;
    }
    _ = drawTextAt(lbl, (screen_w - tw) * 0.5, y + (hint_h - hh) * 0.5, hh, fb.color(0x30, 0x30, 0x30));
}

fn drawStepper(it: Item) void {
    const pressed = item_pressed >= 0 and items[@intCast(item_pressed)].r.x == it.r.x and items[@intCast(item_pressed)].r.y == it.r.y;
    bevel(it.r.x, it.r.y, it.r.w, it.r.h, text_h * 0.1, !pressed, C_BTNFACE);
    const s: []const u8 = if (it.delta < 0) "-" else "+";
    const sw = strWidth(s, text_h);
    _ = drawStr(s, it.r.x + (it.r.w - sw) * 0.5, it.r.y + (it.r.h - text_h) * 0.5, text_h, C_BLACK);
}

fn drawRow(it: Item, idx: usize) void {
    const pressed = item_pressed == @as(i32, @intCast(idx));
    const is_button = it.act == .close or (it.act == .command and (it.arg == ICM_SPLIT or it.arg == ICM_OK or it.arg == ICM_CANCEL));
    if (is_button) {
        bevel(it.r.x, it.r.y, it.r.w, it.r.h, text_h * 0.12, !pressed, if (it.active) fb.color(0xD0, 0xD8, 0xE8) else C_BTNFACE);
        const tw = textWidth(it.label, text_h);
        _ = drawTextAt(it.label, it.r.x + (it.r.w - tw) * 0.5, it.r.y + (it.r.h - text_h) * 0.5, text_h, C_BLACK);
        return;
    }
    if (pressed) solid(it.r.x, it.r.y, it.r.w, it.r.h, fb.color(0xD0, 0xD8, 0xE8));
    var lx = it.r.x + text_h * 0.2;
    if (it.dot) {
        const d = text_h * 0.9;
        drawSprite(U.ui_dot, lx, it.r.y + (it.r.h - d) * 0.5, d, d, C_TITLE);
    }
    lx += text_h * 1.1;
    _ = drawTextAt(it.label, lx, it.r.y + (it.r.h - text_h) * 0.5, text_h, C_BLACK);
    if (it.act == .submenu) {
        const ax = it.r.x + it.r.w - text_h * 0.8;
        _ = drawStr(">", ax, it.r.y + (it.r.h - text_h) * 0.5, text_h, fb.color(0x50, 0x50, 0x50));
    }
}

fn helpLineH() f32 {
    const avail_h = panel_rect.h - text_h * 2.2 - text_h * 2.6;
    const n: f32 = @floatFromInt(U.help_lines);
    var lh = @min(text_h * 1.35, avail_h / n);
    if (lh < text_h * 0.85) lh = text_h * 0.85;
    return lh;
}
fn helpMaxScroll() f32 {
    const avail_h = panel_rect.h - text_h * 2.2 - text_h * 2.6;
    const content = helpLineH() * @as(f32, @floatFromInt(U.help_lines));
    return @max(0, content - avail_h);
}

fn drawHelpBody() void {
    const y0 = panel_rect.y + text_h * 2.2;
    const avail_h = panel_rect.h - text_h * 2.2 - text_h * 2.6;
    const lh = helpLineH();
    var y = y0 - help_scroll;
    var i: u16 = 0;
    while (i < U.help_lines) : (i += 1) {
        if (y + lh >= y0 and y <= y0 + avail_h) {
            const idx = U.hp_01 + i;
            _ = drawTextAt(idx, panel_rect.x + text_h * 1.0, y, lh, C_BLACK);
        }
        y += lh;
    }
    if (helpMaxScroll() > 0) {
        const bar_h = avail_h * (avail_h / (lh * @as(f32, @floatFromInt(U.help_lines))));
        const bar_y = y0 + (avail_h - bar_h) * (help_scroll / helpMaxScroll());
        solid(panel_rect.x + panel_rect.w - text_h * 0.55, bar_y, text_h * 0.2, bar_h, fb.color(0x70, 0x70, 0x70));
    }
}

fn drawScoresBody() void {
    const scores = if (scores_mode == .hyper) hyper_scores else cplx_scores;
    const labels = [3]u16{ U.sc_beg, U.sc_int, U.sc_exp };
    var y = panel_rect.y + text_h * 2.6;
    const row_h = text_h * 2.2;
    const lx = panel_rect.x + text_h * 1.4;
    const rx = panel_rect.x + panel_rect.w - text_h * 1.4;
    for (0..3) |i| {
        _ = drawTextAt(labels[i], lx, y, text_h, C_BLACK);
        const s = scores[i];
        if (s > 0) {
            var buf: [16]u8 = undefined;
            const t = std.fmt.bufPrint(&buf, "{d}", .{s}) catch "";
            const tw = strWidth(t, text_h) + text_h * 0.3 + textWidth(U.sc_sec, text_h);
            var x = rx - tw;
            x = drawStr(t, x, y, text_h, C_BLACK);
            _ = drawTextAt(U.sc_sec, x + text_h * 0.3, y, text_h, C_BLACK);
        } else {
            _ = drawTextAt(U.sc_none, rx - textWidth(U.sc_none, text_h), y, text_h, C_BLACK);
        }
        y += row_h;
    }
}

fn drawAboutBody() void {
    const lines = [_]u16{ U.ab_l1, U.ab_l2, U.ab_l3, U.ab_l4, U.ab_l5, U.ab_l6 };
    var hh = text_h;
    var maxw: f32 = 0;
    for (lines) |l| maxw = @max(maxw, textWidth(l, text_h));
    const avail_w = panel_rect.w - text_h * 2.0;
    if (maxw > avail_w) hh = text_h * avail_w / maxw;
    var y = panel_rect.y + text_h * 3.0;
    for (lines) |l| {
        const w2 = textWidth(l, hh);
        _ = drawTextAt(l, panel_rect.x + (panel_rect.w - w2) * 0.5, y, hh, C_BLACK);
        y += hh * 1.8;
    }
}

fn drawCustomExtra() void {
    for (0..6) |i| {
        const r = cu_rows[i];
        const lbl: u16 = if (i == 0)
            U.cu_height
        else if (i == 1)
            U.cu_width
        else if (hyper())
            switch (i) {
                2 => U.cu_h1,
                3 => U.cu_h2,
                4 => U.cu_h3,
                else => U.cu_h4,
            }
        else switch (i) {
            2 => U.cu_t1,
            3 => U.cu_t2,
            4 => U.cu_t3,
            else => U.cu_t4,
        };
        const ty = r.y + (r.h - text_h) * 0.5;
        _ = drawTextAt(lbl, r.x, ty, text_h, C_BLACK);
        const v: i32 = switch (i) {
            0 => dlg_h,
            1 => dlg_w,
            else => dlg_t[i - 1],
        };
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch "";
        const vw2 = strWidth(s, text_h);
        _ = drawStr(s, cu_val_x + cu_val_w - vw2, ty, text_h, C_BLACK);
    }
    // 范围提示：紧跟在标签右侧（不能右对齐，否则会压住加号按钮）
    const hint_c = fb.color(0x60, 0x60, 0x60);
    const hh = text_h * 0.8;
    const hy = cu_rows[0].y + (cu_rows[0].h - hh) * 0.5;
    _ = drawTextAt(U.cu_rows, cu_rows[0].x + textWidth(U.cu_height, text_h) + text_h * 0.7, hy, hh, hint_c);
    _ = drawTextAt(U.cu_cols, cu_rows[1].x + textWidth(U.cu_width, text_h) + text_h * 0.7, cu_rows[1].y + (cu_rows[1].h - hh) * 0.5, hh, hint_c);
    if (dlg_err != .none) {
        const e: u16 = switch (dlg_err) {
            .height => U.cu_e_height,
            .width => U.cu_e_width,
            .sum_zero => U.cu_e_zero,
            .sum_big => U.cu_e_big,
            .none => U.cu_e_height,
        };
        _ = drawTextAt(e, cu_btns[0].x, cu_btns[0].y - text_h * 1.35, text_h * 0.85, fb.color(0xB0, 0x00, 0x00));
    }
}


fn drawOverlay() void {
    if (overlay == .none) return;
    // 每帧按当前面板重建布局：面板尺寸、标题与条目几何都取自这里，
    // 否则从顶栏按钮打开的面板会沿用上一次面板的几何（尺寸/标题错位）。
    buildItems();
    // 面板用右下投影与桌面区分，而不是压一层现代风格的深色蒙版：
    // 全屏深色蒙版和这套 Windows 经典灰色控件不是一套语言，看上去会“割裂”。
    const sso = @max(2.0, text_h * 0.14);
    solid(panel_rect.x + sso, panel_rect.y + sso, panel_rect.w, panel_rect.h, C_DROP);
    bevel(panel_rect.x, panel_rect.y, panel_rect.w, panel_rect.h, text_h * 0.14, true, C_BTNFACE);
    const th = text_h * 1.5;
    solid(panel_rect.x + text_h * 0.3, panel_rect.y + text_h * 0.35, panel_rect.w - text_h * 0.6, th, C_TITLE);
    const tw = textWidth(panel_title, text_h);
    var title_h = text_h;
    var title_x = panel_rect.x + (panel_rect.w - tw) * 0.5;
    if (tw > panel_rect.w - text_h) {
        title_h = text_h * (panel_rect.w - text_h) / tw;
        title_x = panel_rect.x + (panel_rect.w - textWidth(panel_title, title_h)) * 0.5;
    }
    _ = drawTextAt(panel_title, title_x, panel_rect.y + text_h * 0.35 + (th - title_h) * 0.5, title_h, C_WHITE);

    for (0..item_count) |i| {
        const it = items[i];
        switch (it.act) {
            .stepper => drawStepper(it),
            .command, .submenu, .close => drawRow(it, i),
            .none => {},
        }
    }
    switch (overlay) {
        .custom => drawCustomExtra(),
        .scores => drawScoresBody(),
        .help => drawHelpBody(),
        .about => drawAboutBody(),
        else => {},
    }
}

// ------------------------------------------------------------------ 命令
fn splitCounts() void {
    var sum: i32 = 0;
    for (1..5) |k| sum += dlg_t[k];
    if (sum <= 0) sum = 99;
    const sp = g.splitEvenly(@intCast(@min(sum, 999)));
    for (1..5) |t| dlg_t[t] = sp[t];
    dirty = true;
}

fn stepField(field: i32, delta: i32) void {
    switch (field) {
        0 => dlg_h = std.math.clamp(dlg_h + delta, 9, 30),
        1 => dlg_w = std.math.clamp(dlg_w + delta, 9, 40),
        else => {
            const k: usize = @intCast(field - 1);
            dlg_t[k] = std.math.clamp(dlg_t[k] + delta, 0, 999);
        },
    }
    dlg_err = .none;
    dirty = true;
}

fn openCustom() void {
    dlg_h = game.h;
    dlg_w = game.w;
    var tc = game.type_count;
    var any: u16 = 0;
    for (1..5) |t| any += tc[t];
    if (any == 0) tc = g.splitEvenly(game.mines);
    for (1..5) |t| dlg_t[t] = tc[t];
    dlg_err = .none;
    overlay = .custom;
    dirty = true;
}

fn dlgApply() void {
    var sum: i32 = 0;
    for (1..5) |k| sum += dlg_t[k];
    if (dlg_h < 9 or dlg_h > 30) {
        dlg_err = .height;
        dirty = true;
        return;
    }
    if (dlg_w < 9 or dlg_w > 40) {
        dlg_err = .width;
        dirty = true;
        return;
    }
    if (sum < 1) {
        dlg_err = .sum_zero;
        dirty = true;
        return;
    }
    if (sum > dlg_w * dlg_h - 9) {
        dlg_err = .sum_big;
        dirty = true;
        return;
    }
    dlg_err = .none;
    game.w = @intCast(dlg_w);
    game.h = @intCast(dlg_h);
    game.mines = @intCast(sum);
    game.type_count = .{ 0, @intCast(dlg_t[1]), @intCast(dlg_t[2]), @intCast(dlg_t[3]), @intCast(dlg_t[4]) };
    overlay = .none;
    applyCustomFromDialog();
}

fn showScores(highlight: bool, m: g.Mode) void {
    scores_mode = m;
    scores_highlight = highlight;
    overlay = .scores;
    dirty = true;
}

fn handleCommand(id: i32) void {
    var keep_open = false;
    switch (id) {
        IDM_NEW => startNewGame(null),
        IDM_BEGINNER => setPreset(0, .complex),
        IDM_INTERMEDIATE => setPreset(1, .complex),
        IDM_EXPERT => setPreset(2, .complex),
        IDM_CUSTOM => {
            openCustom();
            keep_open = true;
        },
        IDM_HYPER_BEGINNER => setPreset(0, .hyper),
        IDM_HYPER_INTERMEDIATE => setPreset(1, .hyper),
        IDM_HYPER_EXPERT => setPreset(2, .hyper),
        IDM_HYPER_CUSTOM => {
            openCustom();
            keep_open = true;
        },
        IDM_BEST => {
            showScores(false, .complex);
            keep_open = true;
        },
        IDM_HYPER_BEST => {
            showScores(false, .hyper);
            keep_open = true;
        },
        IDM_SOUND => toggleSound(),
        IDM_ZOOM_AUTO => setViewMag(1.0),
        IDM_ZOOM1 => setViewMag(1.5),
        IDM_ZOOM2 => setViewMag(2.0),
        IDM_ZOOM3 => setViewMag(3.0),
        IDM_ZOOM4 => setViewMag(4.0),
        IDM_HELP_HOW => {
            overlay = .help;
            help_scroll = 0;
            keep_open = true;
        },
        IDM_HELP_ABOUT => {
            overlay = .about;
            keep_open = true;
        },
        ICM_SPLIT => splitCounts(),
        ICM_OK => {
            dlgApply();
            keep_open = overlay != .none;
        },
        ICM_CANCEL => {},
        else => {},
    }
    if (!keep_open) overlay = .none;
    dirty = true;
}

// ------------------------------------------------------------------ 触摸
var touch_down = false;
var touch_x: f32 = 0;
var touch_y: f32 = 0;
var touch_start: u32 = 0;
var long_fired = false;
var last_move_y: f32 = 0;

fn hitItems(x: f32, y: f32) i32 {
    var i: usize = 0;
    while (i < item_count) : (i += 1) {
        const r = items[i].r;
        if (x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h) return @intCast(i);
    }
    return -1;
}
fn hitTop(x: f32, y: f32) i32 {
    if (y >= top_h) return -1;
    for (0..5) |i| {
        const r = tb_rects[i];
        if (x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h) return @intCast(i);
    }
    return -1;
}

fn toFbX(x: f32) f32 {
    return (x - game_x) / game_scale;
}
fn toFbY(y: f32) f32 {
    return (y - game_y) / game_scale;
}

fn cellAtF(L: Layout, px: f32, py: f32) i32 {
    const cf = @as(f32, @floatFromInt(L.cell));
    const cx = (px - @as(f32, @floatFromInt(L.board_x))) / cf;
    const cy = (py - @as(f32, @floatFromInt(L.board_y))) / cf;
    if (cx < 0 or cy < 0) return -1;
    const c: i32 = @intFromFloat(cx);
    const r: i32 = @intFromFloat(cy);
    if (c >= game.w or r >= game.h) return -1;
    return r * @as(i32, game.w) + c;
}
fn inFaceF(L: Layout, px: f32, py: f32) bool {
    const fw = @as(f32, @floatFromInt(FACE_SIZE * L.z));
    const fx = @as(f32, @floatFromInt(faceLeft(L)));
    const fy = @as(f32, @floatFromInt(faceTop(L)));
    return px >= fx and py >= fy and px < fx + fw and py < fy + fw;
}

fn topAction(i: i32) void {
    switch (i) {
        0 => overlay = if (overlay == .none) .menu else .none,
        1 => {
            flag_mode = !flag_mode;
            savePrefs();
        },
        2 => startNewGame(null),
        3 => zoomStep(-1),
        4 => zoomStep(1),
        else => {},
    }
    dirty = true;
}

fn activate(idx: usize) void {
    const it = items[idx];
    switch (it.act) {
        .command => handleCommand(it.arg),
        .submenu => {
            overlay = @enumFromInt(@as(u8, @intCast(it.arg)));
            dirty = true;
        },
        .stepper => stepField(it.arg, it.delta),
        .close => {
            overlay = .none;
            dirty = true;
        },
        .none => {},
    }
}

fn onDown(x: f32, y: f32) void {
    touch_down = true;
    touch_x = x;
    touch_y = y;
    last_move_x = x;
    last_move_y = y;
    pan_mode = false;
    touch_start = nowMs();
    long_fired = false;
    if (overlay != .none) {
        buildItems();
        item_pressed = hitItems(x, y);
        dirty = true;
        return;
    }
    const tb = hitTop(x, y);
    if (tb >= 0) {
        tb_pressed = tb;
        dirty = true;
        return;
    }
    const L = layout();
    const fx = toFbX(x);
    const fy = toFbY(y);
    if (inFaceF(L, fx, fy)) {
        face_armed = true;
        face_down = true;
        dirty = true;
        return;
    }
    const c = cellAtF(L, fx, fy);
    if (c >= 0 and !game.over) {
        const cu: usize = @intCast(c);
        if (game.open[cu] != 0 and game.mine[cu] == 0 and chordable(cu)) {
            chord_cell = c;
        } else if (game.open[cu] == 0) {
            press_cell = c;
        }
    }
    dirty = true;
}

fn onMove(x: f32, y: f32) void {
    if (overlay != .none) {
        if (overlay == .help and touch_down) {
            help_scroll -= (y - last_move_y);
            const mx = helpMaxScroll();
            if (help_scroll < 0) help_scroll = 0;
            if (help_scroll > mx) help_scroll = mx;
            last_move_y = y;
            dirty = true;
        }
        return;
    }
    if (!touch_down) return;
    // 放大后单指拖动 = 平移画面；拖动超过阈值就取消这次点击，避免误触
    if (view_mag > 1.01) {
        const dx = x - touch_x;
        const dy = y - touch_y;
        const slop = text_h * 0.45;
        if (!pan_mode and (dx * dx + dy * dy) > slop * slop) {
            pan_mode = true;
            press_cell = -1;
            chord_cell = -1;
            last_move_x = x;
            last_move_y = y;
        }
        if (pan_mode) {
            view_x += x - last_move_x;
            view_y += y - last_move_y;
            last_move_x = x;
            last_move_y = y;
            clampView();
            dirty = true;
            return;
        }
    }
    if (long_fired) return;
    const L = layout();
    const c = cellAtF(L, toFbX(x), toFbY(y));
    if (chord_cell >= 0) {
        if (c != chord_cell) {
            chord_cell = c;
            dirty = true;
        }
        return;
    }
    if (press_cell < 0) return;
    const next: i32 = if (c >= 0 and game.open[@intCast(c)] == 0) c else -1;
    if (next != press_cell) {
        press_cell = next;
        dirty = true;
    }
}

fn onUp(x: f32, y: f32) void {
    touch_down = false;
    pan_mode = false;
    if (overlay != .none) {
        const hit = hitItems(x, y);
        const was = item_pressed;
        item_pressed = -1;
        if (was >= 0 and hit == was) activate(@intCast(was));
        dirty = true;
        return;
    }
    if (tb_pressed >= 0) {
        const t = tb_pressed;
        tb_pressed = -1;
        if (hitTop(x, y) == t) topAction(t);
        dirty = true;
        return;
    }
    const L = layout();
    const fx = toFbX(x);
    const fy = toFbY(y);
    if (face_armed) {
        face_armed = false;
        face_down = false;
        if (inFaceF(L, fx, fy)) startNewGame(null);
        dirty = true;
        return;
    }
    const held = press_cell;
    const chord = chord_cell;
    press_cell = -1;
    chord_cell = -1;
    if (chord >= 0) {
        if (cellAtF(L, fx, fy) == chord) doExpand(@intCast(chord));
        dirty = true;
        return;
    }
    if (held >= 0 and cellAtF(L, fx, fy) == held and !game.over) {
        const cu: usize = @intCast(held);
        if (!long_fired) {
            if (flag_mode) {
                if (game.cycleFlag(cu)) flashFace();
            } else {
                revealAt(cu);
            }
        }
    }
    dirty = true;
}

/// 长按：翻开模式下长按插旗，插旗模式下长按翻开
fn checkLongPress() void {
    if (!touch_down or long_fired or overlay != .none) return;
    if (nowMs() -% touch_start < 380) return;
    if (press_cell < 0) return;
    const cu: usize = @intCast(press_cell);
    long_fired = true;
    press_cell = -1;
    if (flag_mode) {
        revealAt(cu);
    } else {
        if (game.cycleFlag(cu)) flashFace();
    }
    dirty = true;
}

// ------------------------------------------------------------------ 画面几何
fn computeGameRect() void {
    if (screen_w <= 0) return;
    // 1) 先算“适应屏幕”时屏幕上一格有多少像素
    const fit_cell = cellPixelsAtFit();
    // 2) 目标格子像素 = 适应屏幕 × 用户放大倍数
    const target = fit_cell * view_mag;
    // 3) 内部渲染倍率取到不小于目标像素（只缩不放），放大后依旧清晰
    var z: i32 = @intFromFloat(@ceil(target / 16.0));
    if (z < 1) z = 1;
    if (z > 8) z = 8;
    // 客户区整块要当纹理上传，GLES2 只保证 MAX_TEXTURE_SIZE ≥ 2048，
    // 超过就下调内部倍率（屏幕上的格子大小由 game_scale 补回来，不受影响）
    while (z > 1) {
        zoom = z;
        const Lc = layout();
        if (Lc.client_w <= TEX_MAX and Lc.client_h <= TEX_MAX) break;
        z -= 1;
    }
    zoom = z;
    const L = layout();
    const sw = @as(f32, @floatFromInt(L.client_w));
    const sh = @as(f32, @floatFromInt(L.client_h));
    game_scale = target / (16.0 * @as(f32, @floatFromInt(z)));
    if (game_scale > 4.0) game_scale = 4.0;
    game_dw = sw * game_scale;
    game_dh = sh * game_scale;
    clampView();
    view_ready = true;
}

/// 适应屏幕时屏幕上一格的像素数
fn cellPixelsAtFit() f32 {
    const z = fitZoom();
    zoom = z;
    const L = layout();
    const avail_h = @max(1.0, screen_h - top_h - hint_h);
    const s2 = @min(screen_w / @as(f32, @floatFromInt(L.client_w)), avail_h / @as(f32, @floatFromInt(L.client_h)));
    return 16.0 * @as(f32, @floatFromInt(z)) * s2;
}

/// 把客户区位置夹在可视区内：装得下就居中，装不下就限制在边缘之内
fn clampView() void {
    const avail_h = @max(1.0, screen_h - top_h - hint_h);
    if (game_dw <= screen_w) view_x = (screen_w - game_dw) * 0.5 else view_x = @max(screen_w - game_dw, @min(0.0, view_x));
    if (game_dh <= avail_h) view_y = top_h + (avail_h - game_dh) * 0.5 else view_y = @max(top_h + avail_h - game_dh, @min(top_h, view_y));
    game_x = view_x;
    game_y = view_y;
}

fn nearMag(v: f32) bool {
    return @abs(view_mag - v) < 0.05;
}

const ZOOM_LEVELS = [_]f32{ 1.0, 1.5, 2.0, 3.0, 4.0 };

fn zoomStep(dir: i32) void {
    var idx: usize = 0;
    for (ZOOM_LEVELS, 0..) |v, i| {
        if (view_mag >= v - 0.02) idx = i;
    }
    if (dir > 0) {
        if (idx + 1 < ZOOM_LEVELS.len) setViewMag(ZOOM_LEVELS[idx + 1]);
    } else {
        if (idx > 0) setViewMag(ZOOM_LEVELS[idx - 1]);
    }
}

/// 改放大倍数：以可视区中心为锚点，放大后同一处仍停在中心
fn setViewMag(m: f32) void {
    var v = m;
    if (v < 1.0) v = 1.0;
    if (v > 4.0) v = 4.0;
    const cx = screen_w * 0.5;
    const cy = top_h + @max(1.0, screen_h - top_h - hint_h) * 0.5;
    if (view_ready and game_scale > 0) {
        const ux = (cx - game_x) / game_scale;
        const uy = (cy - game_y) / game_scale;
        view_mag = v;
        computeGameRect();
        view_x = cx - ux * game_scale;
        view_y = cy - uy * game_scale;
        clampView();
    } else {
        view_mag = v;
        computeGameRect();
    }
    repaint();
    dirty = true;
}

fn fitZoom() i32 {
    var best: i32 = 1;
    var z: i32 = 1;
    const avail_h = screen_h - top_h - hint_h;
    while (z <= 8) : (z += 1) {
        zoom = z;
        const L = layout();
        if (@as(f32, @floatFromInt(L.client_w)) <= screen_w and @as(f32, @floatFromInt(L.client_h)) <= avail_h) best = z;
    }
    return best;
}

// ------------------------------------------------------------------ 导出给平台层
var last_second: i32 = -1;

pub export fn cs_main() void {
    fb.initAtlas();
    const blob = plat.loadUiBlob();
    if (!parseUi(blob)) plat.log("界面图集解析失败");
    if (ui_w > 0) plat.cs_set_ui_tex(ui_px, ui_w, ui_h);
    loadPrefs();
    loadScores();
    var i: usize = 0;
    while (i < snd.count) : (i += 1) {
        const wv = snd.wav(i);
        _ = plat.cs_audio_load(@intCast(i), wv.ptr, wv.len);
    }
    game.mode = .complex;
    cur_preset = 0;
    view_mag = 1.0;
    view_ready = false;
    startNewGame(null);
    plat.logf("复扫雷 Android {s} 启动", .{APP_VERSION});
}

var ui_px: [*]const u8 = undefined;
var ui_w: i32 = 0;
var ui_h: i32 = 0;

fn readU16(b: []const u8, off: usize) u16 {
    return @as(u16, b[off]) | (@as(u16, b[off + 1]) << 8);
}
fn parseUi(b: []const u8) bool {
    if (b.len < 16) return false;
    if (!(b[0] == 'C' and b[1] == 'S' and b[2] == 'U' and b[3] == 'I')) return false;
    const count = readU16(b, 6);
    const aw: i32 = readU16(b, 8);
    const ah: i32 = readU16(b, 10);
    const pix_off: usize = 16 + @as(usize, count) * 12;
    const need: usize = @as(usize, @intCast(aw)) * @as(usize, @intCast(ah)) * 4;
    if (b.len < pix_off + need) return false;
    ui_w = aw;
    ui_h = ah;
    ui_px = b.ptr + pix_off;
    return true;
}

pub export fn cs_on_resize(w: i32, h: i32) void {
    screen_w = @floatFromInt(w);
    screen_h = @floatFromInt(h);
    text_h = @min(@max(screen_h / 34.0, 22.0), 96.0);
    top_h = text_h * 1.9;
    hint_h = text_h * 1.5;
    layoutTopBar();
    computeGameRect();
    repaint();
    dirty = true;
}

pub export fn cs_touch(phase: i32, x: f32, y: f32) void {
    switch (phase) {
        0 => onDown(x, y),
        1 => onMove(x, y),
        2 => onUp(x, y),
        else => {
            touch_down = false;
            press_cell = -1;
            chord_cell = -1;
            face_down = false;
            face_armed = false;
            item_pressed = -1;
            tb_pressed = -1;
            dirty = true;
        },
    }
}

pub export fn cs_frame() void {
    if (screen_w <= 0) return;
    if (game.started and !game.over) {
        const el = nowMs() -% game.t0;
        game.elapsed_ms = el;
        const sec = timerSeconds();
        if (sec != last_second) {
            last_second = sec;
            dirty = true;
        }
        maybePlayTick();
    }
    if (face_flash_until != 0 and nowMs() >= face_flash_until) {
        face_flash_until = 0;
        dirty = true;
    }
    checkLongPress();
    computeGameRect();
    if (dirty) repaint();
    plat.cs_frame_begin();
    plat.cs_draw_game(game_x, game_y, game_dw, game_dh, top_h, screen_h - hint_h);
    drawTopBar();
    drawHint();
    drawOverlay();
    plat.cs_frame_end();
}

fn wantsFrameImpl() i32 {
    if (dirty or touch_down) return 1;
    if (game.started and !game.over) return 1;
    if (face_flash_until != 0) return 1;
    return 0;
}

pub export fn cs_wants_frame() i32 {
    return wantsFrameImpl();
}

pub export fn cs_on_pause() void {
    savePrefs();
}

pub export fn cs_on_resume() void {
    dirty = true;
}

// ------------------------------------------------------------------ 自检钩子
// 与仓库里 main.zig 的 test* 钩子同一用途：给界面自检脚本提供确定性的驱动入口。
pub export fn cs_test_cell_xy(cell: i32, out: [*]f32) void {
    const L = layout();
    const cw: i32 = game.w;
    const r = @divTrunc(cell, cw);
    const c = @mod(cell, cw);
    out[0] = game_x + @as(f32, @floatFromInt(L.board_x + c * L.cell + @divTrunc(L.cell, 2))) * game_scale;
    out[1] = game_y + @as(f32, @floatFromInt(L.board_y + r * L.cell + @divTrunc(L.cell, 2))) * game_scale;
}
pub export fn cs_test_face_xy(out: [*]f32) void {
    const L = layout();
    out[0] = game_x + @as(f32, @floatFromInt(faceLeft(L) + @divTrunc(FACE_SIZE * L.z, 2))) * game_scale;
    out[1] = game_y + @as(f32, @floatFromInt(faceTop(L) + @divTrunc(FACE_SIZE * L.z, 2))) * game_scale;
}
pub export fn cs_test_top_xy(i: i32, out: [*]f32) void {
    layoutTopBar();
    const k: usize = @intCast(std.math.clamp(i, 0, 2));
    out[0] = tb_rects[k].x + tb_rects[k].w * 0.5;
    out[1] = tb_rects[k].y + tb_rects[k].h * 0.5;
}
pub export fn cs_test_panel_title() i32 {
    buildItems();
    return @intCast(panel_title);
}
pub export fn cs_test_item_count() i32 {
    buildItems();
    return @intCast(item_count);
}
pub export fn cs_test_item_xy(i: i32, out: [*]f32) void {
    buildItems();
    const k: usize = @intCast(i);
    if (k >= item_count) {
        out[0] = -1;
        out[1] = -1;
        return;
    }
    out[0] = items[k].r.x + items[k].r.w * 0.5;
    out[1] = items[k].r.y + items[k].r.h * 0.5;
}
pub export fn cs_test_item_rect(i: i32, out: [*]f32) void {
    buildItems();
    const k: usize = @intCast(i);
    if (k >= item_count) {
        out[0] = -1;
        out[1] = -1;
        out[2] = 0;
        out[3] = 0;
        return;
    }
    out[0] = items[k].r.x;
    out[1] = items[k].r.y;
    out[2] = items[k].r.w;
    out[3] = items[k].r.h;
}
pub export fn cs_test_item_label(i: i32) i32 {
    buildItems();
    const k: usize = @intCast(i);
    if (k >= item_count) return -1;
    return @intCast(items[k].label);
}
pub export fn cs_test_click(x: f32, y: f32) void {
    onDown(x, y);
    onUp(x, y);
    dirty = true;
}
pub export fn cs_test_long(x: f32, y: f32) void {
    onDown(x, y);
    touch_start = nowMs() -% 1000;
    checkLongPress();
    onUp(x, y);
    dirty = true;
}
pub export fn cs_test_down(x: f32, y: f32) void {
    onDown(x, y);
}
pub export fn cs_test_move(x: f32, y: f32) void {
    onMove(x, y);
}
pub export fn cs_test_up(x: f32, y: f32) void {
    onUp(x, y);
}
pub export fn cs_test_cmd(id: i32) void {
    handleCommand(id);
}
pub export fn cs_test_preset(idx: i32, mode: i32) void {
    setPreset(idx, if (mode == 1) .hyper else .complex);
}
pub export fn cs_test_flag_mode(v: i32) void {
    flag_mode = v != 0;
    dirty = true;
}
pub export fn cs_test_sound(i: i32) i32 {
    const k: usize = @intCast(i);
    if (k >= sound_log.len) return -1;
    return @intCast(sound_log[k]);
}
pub export fn cs_test_reset_sound() void {
    sound_log = [_]u32{0} ** snd.count;
}
pub export fn cs_test_help_scroll(v: f32) void {
    help_scroll = v;
    dirty = true;
}
pub export fn cs_test_set_now(dummy: i32) void {
    _ = dummy;
}

// ---- 自检钩子：缩放 ----
pub export fn cs_test_set_mag(v: f32) void {
    setViewMag(v);
}
pub export fn cs_test_pan(dx: f32, dy: f32) void {
    view_x += dx;
    view_y += dy;
    clampView();
    repaint();
    dirty = true;
}
pub export fn cs_test_zoom_button(dir: i32) void {
    zoomStep(dir);
}

pub export fn cs_test_stats(out: [*]i32) void {
    out[0] = if (game.over) (if (game.win) @as(i32, 2) else 3) else (if (game.started) @as(i32, 1) else 0);
    out[1] = @intCast(game.moves);
    out[2] = game.w;
    out[3] = game.h;
    out[4] = game.mines;
    out[5] = @intCast(game.n);
    out[6] = @intCast(game.flagsTotal());
    out[7] = @intCast(game.openedCount());
    out[8] = @intCast(game.correctFlags());
    out[9] = @intCast(game.safeCount());
    out[10] = timerSeconds();
    out[11] = cur_preset;
    out[12] = @intFromEnum(game.mode);
    out[13] = @intFromEnum(overlay);
    out[14] = if (flag_mode) @as(i32, 1) else 0;
    out[15] = if (view_mag <= 1.01) @as(i32, 1) else 0;
    out[16] = zoom;
    out[38] = @intFromFloat(16.0 * @as(f32, @floatFromInt(zoom)) * game_scale + 0.5);
    out[39] = @intFromFloat(view_x + 0.5);
    out[40] = @intFromFloat(view_y + 0.5);
    out[17] = cplx_scores[0];
    out[18] = cplx_scores[1];
    out[19] = cplx_scores[2];
    out[20] = hyper_scores[0];
    out[21] = hyper_scores[1];
    out[22] = hyper_scores[2];
    out[23] = fb_w;
    out[24] = fb_h;
    out[25] = dlg_h;
    out[26] = dlg_w;
    out[27] = @intFromEnum(dlg_err);
    out[28] = @intFromFloat(help_scroll);
    out[29] = @intFromEnum(game.msg);
    out[30] = @intCast(game.nbrMineCount(0));
    out[31] = if (game.boom >= 0) game.boom else -1;
    out[32] = if (sound_off) @as(i32, 1) else 0;
    out[33] = wantsFrameImpl();
    out[34] = @intCast(game.typeSum());
    out[35] = @intCast(game.nbrFlagCount(0));
    out[36] = @intCast(game.cellCount());
    out[37] = if (game.started) @as(i32, 1) else 0;
}

pub export fn cs_test_set_dlg(h: i32, w: i32, t1: i32, t2: i32, t3: i32, t4: i32) void {
    dlg_h = h;
    dlg_w = w;
    dlg_t = .{ 0, t1, t2, t3, t4 };
    dirty = true;
}
pub export fn cs_test_scenario(q: i32) void {
    switch (q) {
        0 => startNewGame(12345),
        1 => {
            startNewGame(12345);
            game.startAt(40, nowMs());
            var i: usize = 0;
            while (i < game.n and i < 12) : (i += 1) {
                if (game.mine[i] != 0) _ = game.cycleFlag(i);
            }
            game.elapsed_ms = 42000;
        },
        2 => {
            startNewGame(12345);
            game.startAt(40, nowMs());
            var i: usize = 0;
            while (i < game.n) : (i += 1) {
                if (game.mine[i] != 0) {
                    _ = game.reveal(i, nowMs());
                    break;
                }
            }
            afterGameAction();
        },
        3 => {
            startNewGame(12345);
            game.startAt(40, nowMs());
            var i: usize = 0;
            while (i < game.n) : (i += 1) {
                if (game.mine[i] == 0) game.open[i] = 1;
            }
            i = 0;
            var placed: u32 = 0;
            while (i < game.n and placed < 3) : (i += 1) {
                if (game.mine[i] != 0) {
                    _ = game.setFlag(i, game.mine[i]);
                    placed += 1;
                }
            }
            game.checkWin();
            afterGameAction();
        },
        else => {},
    }
    dirty = true;
}

pub export fn cs_test_find(kind: i32) i32 {
    var i: usize = 0;
    while (i < game.n) : (i += 1) {
        if (kind == 2) {
            if (game.open[i] != 0 and game.mine[i] == 0) {
                var buf: [8]usize = undefined;
                const k = game.nbrs(i, &buf);
                var mines: i32 = 0;
                for (buf[0..k]) |j| {
                    if (game.mine[j] != 0) mines += 1;
                }
                if (mines > 0) return @intCast(i);
            }
        } else if (game.open[i] == 0 and game.flag[i] == 0) {
            if (kind == 0 and game.mine[i] == 0) return @intCast(i);
            if (kind == 1 and game.mine[i] != 0) return @intCast(i);
        }
    }
    return -1;
}
pub export fn cs_test_flag_around(cell: i32) i32 {
    if (cell < 0) return 0;
    var buf: [8]usize = undefined;
    const k = game.nbrs(@intCast(cell), &buf);
    var n: i32 = 0;
    for (buf[0..k]) |j| {
        if (game.mine[j] != 0 and game.flag[j] == 0) {
            _ = game.setFlag(j, game.mine[j]);
            n += 1;
        }
    }
    dirty = true;
    return n;
}
