//! 平台接口绑定：C 侧（platform.c / 主机侧 platform_host.c）实现，Zig 侧调用。
//! 约定：颜色一律 0xRRGGBBAA，坐标一律屏幕像素（左上原点）。
const builtin = @import("builtin");

pub extern fn cs_log(msg: [*]const u8, len: usize) void;
pub extern fn cs_now_ms() u64;
pub extern fn cs_screen_w() i32;
pub extern fn cs_screen_h() i32;
pub extern fn cs_set_fb(px: [*]const u8, w: i32, h: i32) void;
pub extern fn cs_set_ui_tex(px: [*]const u8, w: i32, h: i32) void;
pub extern fn cs_frame_begin() void;
pub extern fn cs_draw_game(x: f32, y: f32, w: f32, h: f32, clip_y0: f32, clip_y1: f32) void;
pub extern fn cs_draw_ui(sx: i32, sy: i32, sw: i32, sh: i32, dx: f32, dy: f32, dw: f32, dh: f32, rgba: u32) void;
pub extern fn cs_frame_end() void;
pub extern fn cs_play_sound(idx: i32) void;
pub extern fn cs_stop_audio() void;
pub extern fn cs_audio_load(idx: i32, wav: [*]const u8, len: usize) i32;
pub extern fn cs_read_file(name: [*:0]const u8, buf: [*]u8, cap: i32) i32;
pub extern fn cs_write_file(name: [*:0]const u8, buf: [*]const u8, len: i32) i32;
pub extern fn cs_inflate(src: [*]const u8, len: usize, out_len: *usize) ?[*]const u8;
pub extern fn cs_exit() void;
pub extern fn malloc(size: usize) ?*anyopaque;
pub extern fn free(ptr: ?*anyopaque) void;

/// 注意：armeabi-v7a 目标的 abi 是 .androideabi 而不是 .android，
/// 必须用 isAndroid() 判定，否则 32 位 ARM 会走主机分支（把未压缩图集编进库里）。
pub const is_android = builtin.abi.isAndroid();

/// 界面图集：Android 上是从内嵌的 zlib 数据解出来的，主机上直接读未压缩的 ui.bin
pub fn loadUiBlob() []const u8 {
    if (is_android) {
        const z = @embedFile("ui.bin.z");
        var n: usize = 0;
        const ptr = cs_inflate(z.ptr, z.len, &n) orelse {
            log("界面图集解压失败");
            return &.{};
        };
        return ptr[0..n];
    }
    return @embedFile("ui.bin");
}

pub fn log(msg: []const u8) void {
    cs_log(msg.ptr, msg.len);
}

pub fn logf(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = @import("std").fmt.bufPrint(&buf, fmt, args) catch return;
    log(s);
}

pub fn nowMs() u32 {
    return @truncate(cs_now_ms());
}
