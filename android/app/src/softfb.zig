//! 软件帧缓冲：把 Win32 版里 GDI 的 fill / DrawEdge / StretchBlt(最近邻) 换成对内存像素的操作。
//! 像素格式与内存里的 RGBA8888 字节序一致（u32 值 = 0xAABBGGRR），可直接上传给 GL。
const A = @import("assets.zig");
const plat = @import("platform.zig");

pub var px: [*]u32 = undefined;
pub var w: i32 = 0;
pub var h: i32 = 0;

pub var atlas_px: [*]u32 = undefined;
pub var atlas_w: i32 = 0;
pub var atlas_h: i32 = 0;

/// 颜色一律 0xRRGGBBAA（与平台层约定一致，直接作为贴图色调使用）
pub fn color(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xFF;
}
pub fn colorA(r: u8, g: u8, b: u8, a: u8) u32 {
    return (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | @as(u32, a);
}

/// 0xRRGGBBAA → 帧缓冲里的像素值。帧缓冲按内存字节序 R,G,B,A 排列（供 GL 直接上传），
/// 小端下即 value = R | G<<8 | B<<16 | A<<24。
inline fn toPixel(c: u32) u32 {
    return ((c >> 24) & 0xFF) | (((c >> 16) & 0xFF) << 8) | (((c >> 8) & 0xFF) << 16) | ((c & 0xFF) << 24);
}

/// 把图集像素从 BGRA（GDI 的 32bpp DIB 顺序）转成 RGBA 字节序，只做一次。
/// 注意素材在只读段里，必须拷到可写内存再改。
pub fn initAtlas() void {
    atlas_w = A.atlas_w;
    atlas_h = A.atlas_h;
    const need: usize = @as(usize, @intCast(atlas_w)) * @as(usize, @intCast(atlas_h));
    const pix_off: usize = 12 + @as(usize, A.count) * 8;
    const raw = plat.malloc(need * 4) orelse {
        plat.log("图集内存分配失败");
        return;
    };
    const dst: [*]u32 = @ptrCast(@alignCast(raw));
    const src: [*]const u32 = @ptrCast(@alignCast(A.blob[pix_off..].ptr));
    var i: usize = 0;
    while (i < need) : (i += 1) {
        const v = src[i];
        // 内存里是 B,G,R,A → 交换 R/B
        dst[i] = (v & 0xFF00FF00) | ((v & 0x000000FF) << 16) | ((v >> 16) & 0x000000FF);
    }
    atlas_px = dst;
}

pub fn setTarget(pixels: [*]u32, cw: i32, ch: i32) void {
    px = pixels;
    w = cw;
    h = ch;
}

pub fn bytes() []const u8 {
    const n: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    return @as([*]const u8, @ptrCast(px))[0..n];
}

pub fn fill(x: i32, y: i32, cw: i32, ch: i32, c_rgba: u32) void {
    if (cw <= 0 or ch <= 0) return;
    const c = toPixel(c_rgba);
    var x0 = x;
    var y0 = y;
    var x1 = x + cw;
    var y1 = y + ch;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > w) x1 = w;
    if (y1 > h) y1 = h;
    if (x0 >= x1 or y0 >= y1) return;
    var yy = y0;
    while (yy < y1) : (yy += 1) {
        const row = px + @as(usize, @intCast(yy)) * @as(usize, @intCast(w));
        var xx = x0;
        while (xx < x1) : (xx += 1) row[@intCast(xx)] = c;
    }
}

/// 经典立体边框：raised = 左上亮、右下暗；sunken 反过来
pub fn draw3d(x: i32, y: i32, cw: i32, ch: i32, t: i32, raised: bool, hi: u32, lo: u32) void {
    const a = if (raised) hi else lo;
    const b = if (raised) lo else hi;
    fill(x, y, cw, t, a);
    fill(x, y, t, ch, a);
    fill(x, y + ch - t, cw, t, b);
    fill(x + cw - t, y, t, ch, b);
}

/// 贴一张图集里的图，按最近邻缩放（等价于原版 SetStretchBltMode(COLORONCOLOR)）
pub fn blit(sprite: u16, x: i32, y: i32, dw: i32, dh: i32) void {
    if (dw <= 0 or dh <= 0) return;
    const r = A.rect(sprite);
    const sw: i32 = r.w;
    const sh: i32 = r.h;
    // 目标裁剪
    var dx0 = x;
    var dy0 = y;
    var dx1 = x + dw;
    var dy1 = y + dh;
    var sx0: i32 = 0;
    var sy0: i32 = 0;
    if (dx0 < 0) {
        sx0 = @divTrunc(-dx0 * sw, dw);
        dx0 = 0;
    }
    if (dy0 < 0) {
        sy0 = @divTrunc(-dy0 * sh, dh);
        dy0 = 0;
    }
    if (dx1 > w) dx1 = w;
    if (dy1 > h) dy1 = h;
    if (dx0 >= dx1 or dy0 >= dy1) return;

    const src_base = atlas_px + @as(usize, r.y) * @as(usize, @intCast(atlas_w)) + @as(usize, r.x);
    var yy = dy0;
    while (yy < dy1) : (yy += 1) {
        const sy = @min(sh - 1, sy0 + @divTrunc((yy - y) * sh, dh));
        const srow = src_base + @as(usize, @intCast(sy)) * @as(usize, @intCast(atlas_w));
        const drow = px + @as(usize, @intCast(yy)) * @as(usize, @intCast(w));
        var xx = dx0;
        while (xx < dx1) : (xx += 1) {
            const sx = @min(sw - 1, sx0 + @divTrunc((xx - x) * sw, dw));
            drow[@intCast(xx)] = srow[@intCast(sx)];
        }
    }
}
