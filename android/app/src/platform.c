// 复扫雷 Android 平台层：NativeActivity 胶水 + EGL/GLES2 渲染 + 触摸输入 + OpenSL ES 音效 + 存档
// 与 Zig 侧的分工：
//   C 负责一切需要 Android NDK 头文件的东西（窗口、GL 上下文、输入队列、音频、文件、zlib）
//   Zig 负责游戏规则、布局与界面（见 android_main.zig / softfb.zig / ui.zig）
// Zig 侧调用的函数都以 cs_ 前缀导出；Zig 侧实现、由 C 回调的函数见下面的 extern 声明。
#include <android_native_app_glue.h>
#include <android/log.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <SLES/OpenSLES.h>
#include <SLES/OpenSLES_Android.h>
#include <zlib.h>
#include "quad_verts.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  "complexsweeper", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "complexsweeper", __VA_ARGS__)

/* ---------------- Zig 侧实现，由本文件回调 ---------------- */
extern void cs_main(void);
extern void cs_on_resize(int w, int h);
extern void cs_touch(int phase, float x, float y);
extern void cs_frame(void);
extern int  cs_wants_frame(void);
extern void cs_on_pause(void);
extern void cs_on_resume(void);

/* ---------------- 顶点格式：像素坐标 + 纹理坐标 + RGBA 色调 ---------------- */
typedef struct { float x, y, u, v; unsigned char r, g, b, a; } Vertex;

#define MAX_QUADS 512
#define VERTS_PER_QUAD 6

typedef struct {
    SLObjectItf obj;
    SLPlayItf play;
    SLAndroidSimpleBufferQueueItf queue;
    short *pcm;
    int frames;
} SoundPlayer;

typedef struct {
    struct android_app *app;
    int has_surface;
    int focused;
    int display_ready;
    EGLDisplay display;
    EGLSurface surface;
    EGLContext context;
    int width, height;

    GLuint prog, tex_game, tex_ui, vbo;
    GLint a_pos, a_uv, a_col, u_inv, u_tex;
    int game_tex_w, game_tex_h, game_tex_alloc;
    int ui_tex_w, ui_tex_h;
    int cs_started;
    EGLConfig egl_cfg;
    GLuint bound_tex;

    Vertex *batch;
    int batch_count;
    GLuint batch_tex;
    int batch_linear;

    SLObjectItf sl_obj, sl_mix;
    SLEngineItf sl_engine;
    SoundPlayer snd[8];
    int snd_count;
    int audio_ready;

    char data_dir[1024];
} Engine;

static Engine g_engine;

/* ============================ GL ============================ */

static const char *VS_SRC =
    "attribute vec2 a_pos;\n"
    "attribute vec2 a_uv;\n"
    "attribute vec4 a_col;\n"
    "uniform vec2 u_inv;\n"
    "varying vec2 v_uv;\n"
    "varying vec4 v_col;\n"
    "void main(){ v_uv = a_uv; v_col = a_col;\n"
    "  gl_Position = vec4(a_pos.x * u_inv.x - 1.0, 1.0 - a_pos.y * u_inv.y, 0.0, 1.0); }\n";

static const char *FS_SRC =
    "precision mediump float;\n"
    "uniform sampler2D u_tex;\n"
    "varying vec2 v_uv;\n"
    "varying vec4 v_col;\n"
    "void main(){ vec4 c = texture2D(u_tex, v_uv); gl_FragColor = vec4(c.rgb * v_col.rgb, c.a * v_col.a); }\n";

static GLuint compile(GLenum type, const char *src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[1024];
        glGetShaderInfoLog(s, sizeof(log), NULL, log);
        LOGE("shader 编译失败: %s", log);
        return 0;
    }
    return s;
}

static int gl_init(Engine *e) {
    GLuint vs = compile(GL_VERTEX_SHADER, VS_SRC);
    GLuint fs = compile(GL_FRAGMENT_SHADER, FS_SRC);
    if (!vs || !fs) return 0;
    e->prog = glCreateProgram();
    glAttachShader(e->prog, vs);
    glAttachShader(e->prog, fs);
    glLinkProgram(e->prog);
    GLint ok = 0;
    glGetProgramiv(e->prog, GL_LINK_STATUS, &ok);
    if (!ok) { LOGE("着色器链接失败"); return 0; }
    e->a_pos = glGetAttribLocation(e->prog, "a_pos");
    e->a_uv  = glGetAttribLocation(e->prog, "a_uv");
    e->a_col = glGetAttribLocation(e->prog, "a_col");
    e->u_inv = glGetUniformLocation(e->prog, "u_inv");
    e->u_tex = glGetUniformLocation(e->prog, "u_tex");

    glGenTextures(1, &e->tex_game);
    glGenTextures(1, &e->tex_ui);
    glGenBuffers(1, &e->vbo);
    e->batch = (Vertex *)malloc(sizeof(Vertex) * MAX_QUADS * VERTS_PER_QUAD);
    if (!e->batch) return 0;
    e->batch_count = 0;
    e->batch_tex = 0;

    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    { GLint mts = 0; glGetIntegerv(GL_MAX_TEXTURE_SIZE, &mts); LOGI("GL_MAX_TEXTURE_SIZE = %d", (int)mts); }
    { char m[256]; if (cs_quad_selftest(m, sizeof m) == 0) LOGI("矩形顶点自检通过"); else LOGE("矩形顶点自检失败：%s", m); }
    glClearColor(0.7529f, 0.7529f, 0.7529f, 1.0f); /* Windows 经典灰 #C0C0C0，与界面同色，避免露底 */
    return 1;
}

static void batch_flush(Engine *e) {
    if (e->batch_count == 0) return;
    glBindTexture(GL_TEXTURE_2D, e->batch_tex);
    glBufferSubData(GL_ARRAY_BUFFER, 0, sizeof(Vertex) * e->batch_count * VERTS_PER_QUAD, e->batch);
    glDrawArrays(GL_TRIANGLES, 0, e->batch_count * VERTS_PER_QUAD);
    e->batch_count = 0;
}

static void batch_use(Engine *e, GLuint tex) {
    if (e->batch_tex == tex) return;
    batch_flush(e);
    e->batch_tex = tex;
}

static void batch_quad(Engine *e, float x, float y, float w, float h,
                       float u0, float v0, float u1, float v1, unsigned int rgba) {
    if (e->batch_count >= MAX_QUADS) batch_flush(e);
    Vertex *v = e->batch + e->batch_count * VERTS_PER_QUAD;
    unsigned char r = (rgba >> 24) & 0xFF, g = (rgba >> 16) & 0xFF;
    unsigned char b = (rgba >> 8) & 0xFF, a = rgba & 0xFF;
    float xs[6], ys[6], us[6], vs[6];
    cs_quad_verts(x, y, w, h, u0, v0, u1, v1, xs, ys, us, vs);
    for (int i = 0; i < 6; i++) {
        v[i].x = xs[i]; v[i].y = ys[i];
        v[i].u = us[i]; v[i].v = vs[i];
        v[i].r = r; v[i].g = g; v[i].b = b; v[i].a = a;
    }
    e->batch_count++;
}

/* ============================ EGL ============================ */

static int egl_init(Engine *e) {
    EGLDisplay d = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (d == EGL_NO_DISPLAY) { LOGE("eglGetDisplay 失败"); return 0; }
    if (!eglInitialize(d, NULL, NULL)) { LOGE("eglInitialize 失败"); return 0; }
    e->display = d;

    const EGLint attrs8888[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 0, EGL_STENCIL_SIZE, 0, EGL_NONE
    };
    const EGLint attrs565[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 5, EGL_GREEN_SIZE, 6, EGL_BLUE_SIZE, 5,
        EGL_DEPTH_SIZE, 0, EGL_STENCIL_SIZE, 0, EGL_NONE
    };
    EGLConfig cfg = NULL;
    EGLint n = 0;
    if (!eglChooseConfig(d, attrs8888, &cfg, 1, &n) || n < 1) {
        if (!eglChooseConfig(d, attrs565, &cfg, 1, &n) || n < 1) {
            LOGE("找不到可用的 EGLConfig");
            return 0;
        }
    }
    const EGLint ctx_attrs[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    e->egl_cfg = cfg;
    e->context = eglCreateContext(d, cfg, EGL_NO_CONTEXT, ctx_attrs);
    if (e->context == EGL_NO_CONTEXT) { LOGE("eglCreateContext 失败"); return 0; }
    e->display_ready = 1;
    return 1;
}

static void surface_create(Engine *e) {
    if (!e->display_ready || !e->app->window) return;
    if (e->surface != EGL_NO_SURFACE) return;
    EGLint nat_attrs[] = { EGL_NONE };
    e->surface = eglCreateWindowSurface(e->display, e->egl_cfg, e->app->window, nat_attrs);
    if (e->surface == EGL_NO_SURFACE) {
        EGLConfig cfg;
        EGLint n = 0;
        eglGetConfigs(e->display, &cfg, 1, &n);
        if (n > 0) e->surface = eglCreateWindowSurface(e->display, cfg, e->app->window, nat_attrs);
    }
    if (e->surface == EGL_NO_SURFACE) { LOGE("eglCreateWindowSurface 失败"); return; }
    eglMakeCurrent(e->display, e->surface, e->surface, e->context);
    e->has_surface = 1;
    e->width = ANativeWindow_getWidth(e->app->window);
    e->height = ANativeWindow_getHeight(e->app->window);
    glViewport(0, 0, e->width, e->height);
    if (!gl_init(e)) { LOGE("GL 初始化失败"); return; }
    glBindBuffer(GL_ARRAY_BUFFER, e->vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(Vertex) * MAX_QUADS * VERTS_PER_QUAD, NULL, GL_STREAM_DRAW);
    glEnableVertexAttribArray(e->a_pos);
    glEnableVertexAttribArray(e->a_uv);
    glEnableVertexAttribArray(e->a_col);
    glVertexAttribPointer(e->a_pos, 2, GL_FLOAT, GL_FALSE, sizeof(Vertex), (void *)0);
    glVertexAttribPointer(e->a_uv, 2, GL_FLOAT, GL_FALSE, sizeof(Vertex), (void *)(2 * sizeof(float)));
    glVertexAttribPointer(e->a_col, 4, GL_UNSIGNED_BYTE, GL_TRUE, sizeof(Vertex), (void *)(4 * sizeof(float)));
    glUseProgram(e->prog);
    glUniform1i(e->u_tex, 0);
    glActiveTexture(GL_TEXTURE0);
    LOGI("surface 就绪 %dx%d", e->width, e->height);
    if (!e->cs_started) {       // GL 上下文就绪之后才能建纹理，Zig 侧在这里起步
        e->cs_started = 1;
        cs_main();
    }
    cs_on_resize(e->width, e->height);
}

static void surface_destroy(Engine *e) {
    if (e->surface != EGL_NO_SURFACE) {
        eglMakeCurrent(e->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroySurface(e->display, e->surface);
        e->surface = EGL_NO_SURFACE;
    }
    e->has_surface = 0;
    e->batch_count = 0;
    e->batch_tex = 0;
    e->game_tex_alloc = 0;
    e->tex_game = 0;
    e->tex_ui = 0;
}

/* ============================ 音频（OpenSL ES） ============================ */

static int audio_init(Engine *e) {
    if (slCreateEngine(&e->sl_obj, 0, NULL, 0, NULL, NULL) != SL_RESULT_SUCCESS) return 0;
    if ((*e->sl_obj)->Realize(e->sl_obj, SL_BOOLEAN_FALSE) != SL_RESULT_SUCCESS) return 0;
    if ((*e->sl_obj)->GetInterface(e->sl_obj, SL_IID_ENGINE, &e->sl_engine) != SL_RESULT_SUCCESS) return 0;
    if ((*e->sl_engine)->CreateOutputMix(e->sl_engine, &e->sl_mix, 0, NULL, NULL) != SL_RESULT_SUCCESS) return 0;
    if ((*e->sl_mix)->Realize(e->sl_mix, SL_BOOLEAN_FALSE) != SL_RESULT_SUCCESS) return 0;
    e->audio_ready = 1;
    LOGI("OpenSL ES 就绪");
    return 1;
}

/* ============================ 对外（Zig 调用） ============================ */

void cs_log(const unsigned char *msg, size_t len) {
    char buf[512];
    size_t n = len < sizeof(buf) - 1 ? len : sizeof(buf) - 1;
    memcpy(buf, msg, n);
    buf[n] = 0;
    LOGI("%s", buf);
}

uint64_t cs_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ull + (uint64_t)(ts.tv_nsec / 1000000);
}

int cs_screen_w(void) { return g_engine.width; }
int cs_screen_h(void) { return g_engine.height; }

/* 把 Zig 侧的帧缓冲（RGBA8888，自顶向下）交给 GPU */
void cs_set_fb(const unsigned char *px, int w, int h) {
    Engine *e = &g_engine;
    if (!e->has_surface || w <= 0 || h <= 0) return;
    glBindTexture(GL_TEXTURE_2D, e->tex_game);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    if (e->game_tex_w != w || e->game_tex_h != h) {
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        e->game_tex_w = w; e->game_tex_h = h;
    } else {
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, px);
    }
}

void cs_set_ui_tex(const unsigned char *px, int w, int h) {
    Engine *e = &g_engine;
    if (!e->has_surface) return;
    glBindTexture(GL_TEXTURE_2D, e->tex_ui);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    e->ui_tex_w = w;
    e->ui_tex_h = h;
    GLenum err = glGetError();
    if (err != GL_NO_ERROR) {
        LOGE("界面图集纹理上传失败 0x%x（%dx%d）：超出 GL_MAX_TEXTURE_SIZE 时整块界面都会画错", err, w, h);
    } else {
        LOGI("界面图集纹理 %dx%d 上传成功", w, h);
    }
}

void cs_frame_begin(void) {
    Engine *e = &g_engine;
    if (!e->has_surface) return;
    glViewport(0, 0, e->width, e->height);
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(e->prog);
    glUniform2f(e->u_inv, 2.0f / (float)e->width, 2.0f / (float)e->height);
    e->batch_count = 0;
    e->batch_tex = 0;
    e->bound_tex = 0;
}

/* 客户区（棋盘）上屏。放大后客户区会超出屏幕，这里按可视区裁剪四边形与 UV，
   不用 GL 裁剪状态（批次是延迟绘制的，裁剪状态在真正绘制时未必还有效）。 */
void cs_draw_game(float x, float y, float w, float h, float clip_y0, float clip_y1) {
    Engine *e = &g_engine;
    if (!e->has_surface || e->game_tex_w <= 0 || w <= 0 || h <= 0) return;
    float x0 = x, x1 = x + w, y0 = y, y1 = y + h;
    if (x0 < 0) x0 = 0;
    if (x1 > (float)e->width) x1 = (float)e->width;
    if (y0 < clip_y0) y0 = clip_y0;
    if (y1 > clip_y1) y1 = clip_y1;
    if (x1 <= x0 || y1 <= y0) return;
    batch_use(e, e->tex_game);
    batch_quad(e, x0, y0, x1 - x0, y1 - y0,
               (x0 - x) / w, (y0 - y) / h, (x1 - x) / w, (y1 - y) / h, 0xFFFFFFFFu);
}

/* 从界面图集里贴一块（屏幕像素坐标；rgba 为 0xRRGGBBAA 色调） */
void cs_draw_ui(int sx, int sy, int sw, int sh, float dx, float dy, float dw, float dh, unsigned int rgba) {
    Engine *e = &g_engine;
    if (!e->has_surface) return;
    batch_use(e, e->tex_ui);
    float tw = (float)(e->ui_tex_w > 0 ? e->ui_tex_w : 1);
    float th = (float)(e->ui_tex_h > 0 ? e->ui_tex_h : 1);
    float u0 = (float)sx / tw;
    float v0 = (float)sy / th;
    float u1 = (float)(sx + sw) / tw;
    float v1 = (float)(sy + sh) / th;
    batch_quad(e, dx, dy, dw, dh, u0, v0, u1, v1, rgba);
}

void cs_frame_end(void) {
    Engine *e = &g_engine;
    if (!e->has_surface) return;
    batch_flush(e);
    eglSwapBuffers(e->display, e->surface);
}

void cs_exit(void) { ANativeActivity_finish(g_engine.app->activity); }

/* 加载一段音效：Zig 侧把内嵌的 wav 原始字节交过来，这里转成 16 位 PCM 交给 OpenSL ES */
int cs_audio_load(int idx, const unsigned char *wav, size_t len) {
    Engine *e = &g_engine;
    if (!e->audio_ready || idx < 0 || idx >= 8 || len < 44) return 0;
    size_t off = 12;
    while (off + 8 <= len) {
        unsigned int csize = (unsigned int)wav[off + 4] | ((unsigned int)wav[off + 5] << 8) |
                             ((unsigned int)wav[off + 6] << 16) | ((unsigned int)wav[off + 7] << 24);
        if (wav[off] == 'd' && wav[off + 1] == 'a' && wav[off + 2] == 't' && wav[off + 3] == 'a') {
            size_t start = off + 8;
            size_t n = csize;
            if (start + n > len) n = len - start;
            int frames = (int)n;
            short *pcm = (short *)malloc((size_t)frames * 2);
            if (!pcm) return 0;
            for (int i = 0; i < frames; i++) {
                int v = ((int)wav[start + i] - 128) << 8;   // 8bit 无符号 → 16bit 有符号
                pcm[i] = (short)v;
            }
            SoundPlayer *sp = &e->snd[idx];
            SLDataLocator_AndroidSimpleBufferQueue loc = { SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE, 2 };
            SLDataFormat_PCM fmt = {
                SL_DATAFORMAT_PCM, 1, SL_SAMPLINGRATE_22_05,
                SL_PCMSAMPLEFORMAT_FIXED_16, SL_PCMSAMPLEFORMAT_FIXED_16,
                SL_SPEAKER_FRONT_CENTER, SL_BYTEORDER_LITTLEENDIAN
            };
            SLDataSource src = { &loc, &fmt };
            SLDataLocator_OutputMix outloc = { SL_DATALOCATOR_OUTPUTMIX, e->sl_mix };
            SLDataSink sink = { &outloc, NULL };
            const SLInterfaceID ids[1] = { SL_IID_ANDROIDSIMPLEBUFFERQUEUE };
            const SLboolean req[1] = { SL_BOOLEAN_TRUE };
            if ((*e->sl_engine)->CreateAudioPlayer(e->sl_engine, &sp->obj, &src, &sink, 1, ids, req) != SL_RESULT_SUCCESS) {
                free(pcm);
                return 0;
            }
            if ((*sp->obj)->Realize(sp->obj, SL_BOOLEAN_FALSE) != SL_RESULT_SUCCESS) { free(pcm); return 0; }
            if ((*sp->obj)->GetInterface(sp->obj, SL_IID_PLAY, &sp->play) != SL_RESULT_SUCCESS) { free(pcm); return 0; }
            if ((*sp->obj)->GetInterface(sp->obj, SL_IID_ANDROIDSIMPLEBUFFERQUEUE, &sp->queue) != SL_RESULT_SUCCESS) { free(pcm); return 0; }
            sp->pcm = pcm;
            sp->frames = frames;
            if (idx + 1 > e->snd_count) e->snd_count = idx + 1;
            return 1;
        }
        off += 8 + csize + (csize & 1);
    }
    return 0;
}

void cs_play_sound(int idx) {
    Engine *e = &g_engine;
    if (!e->audio_ready || idx < 0 || idx >= e->snd_count) return;
    SoundPlayer *sp = &e->snd[idx];
    if (!sp->queue) return;
    (*sp->queue)->Enqueue(sp->queue, sp->pcm, (SLuint32)(sp->frames * 2));
    (*sp->play)->SetPlayState(sp->play, SL_PLAYSTATE_PLAYING);
}

void cs_stop_audio(void) {
    Engine *e = &g_engine;
    for (int i = 0; i < e->snd_count; i++) {
        SoundPlayer *sp = &e->snd[i];
        if (!sp->play) continue;
        (*sp->play)->SetPlayState(sp->play, SL_PLAYSTATE_STOPPED);
        if (sp->queue) (*sp->queue)->Clear(sp->queue);
    }
}

/* zlib 解压（界面图集压缩后内嵌，设备端解出来用） */
const unsigned char *cs_inflate(const unsigned char *src, size_t len, size_t *out_len) {
    size_t cap = 64u * 1024u * 1024u;
    unsigned char *buf = (unsigned char *)malloc(cap);
    if (!buf) return NULL;
    uLongf n = (uLongf)cap; /* zlib 的 destLen 是 uLongf，不能用 size_t（32 位下类型不同） */
    int rc = uncompress(buf, &n, src, (uLong)len);
    if (rc != Z_OK) { free(buf); LOGE("zlib 解压失败 %d", rc); return NULL; }
    *out_len = (size_t)n;
    return buf;
}

/* 存档：读写应用私有目录下的文件 */
static void build_path(char *out, size_t cap, const char *name) {
    snprintf(out, cap, "%s/%s", g_engine.data_dir, name);
}

int cs_read_file(const char *name, unsigned char *buf, int cap) {
    char path[1200];
    build_path(path, sizeof(path), name);
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    int n = (int)fread(buf, 1, (size_t)cap, f);
    fclose(f);
    return n;
}

int cs_write_file(const char *name, const unsigned char *buf, int len) {
    char path[1200];
    build_path(path, sizeof(path), name);
    FILE *f = fopen(path, "wb");
    if (!f) return 0;
    int n = (int)fwrite(buf, 1, (size_t)len, f);
    fclose(f);
    return n == len;
}

/* ============================ 生命周期 / 输入 ============================ */

static void handle_cmd(struct android_app *app, int32_t cmd) {
    Engine *e = &g_engine;
    switch (cmd) {
        case APP_CMD_INIT_WINDOW:
            if (app->window) surface_create(e);
            break;
        case APP_CMD_TERM_WINDOW:
            surface_destroy(e);
            break;
        case APP_CMD_WINDOW_RESIZED:
        case APP_CMD_CONFIG_CHANGED:
            if (app->window && e->has_surface) {
                e->width = ANativeWindow_getWidth(app->window);
                e->height = ANativeWindow_getHeight(app->window);
                glViewport(0, 0, e->width, e->height);
                cs_on_resize(e->width, e->height);
            }
            break;
        case APP_CMD_GAINED_FOCUS:
            e->focused = 1;
            cs_on_resume();
            break;
        case APP_CMD_LOST_FOCUS:
            e->focused = 0;
            cs_on_pause();
            break;
        case APP_CMD_PAUSE:
            cs_on_pause();
            break;
        case APP_CMD_RESUME:
            cs_on_resume();
            break;
        case APP_CMD_DESTROY:
            LOGI("退出");
            break;
        default:
            break;
    }
}

static int32_t handle_input(struct android_app *app, AInputEvent *event) {
    Engine *e = &g_engine;
    if (AInputEvent_getType(event) != AINPUT_EVENT_TYPE_MOTION) return 0;
    int32_t action = AMotionEvent_getAction(event) & AMOTION_EVENT_ACTION_MASK;
    float x = AMotionEvent_getX(event, 0);
    float y = AMotionEvent_getY(event, 0);
    switch (action) {
        case AMOTION_EVENT_ACTION_DOWN:
            cs_touch(0, x, y);
            return 1;
        case AMOTION_EVENT_ACTION_MOVE:
            cs_touch(1, x, y);
            return 1;
        case AMOTION_EVENT_ACTION_UP:
            cs_touch(2, x, y);
            return 1;
        case AMOTION_EVENT_ACTION_CANCEL:
        case AMOTION_EVENT_ACTION_POINTER_UP:
        case AMOTION_EVENT_ACTION_POINTER_DOWN:
            cs_touch(3, x, y);
            return 1;
        default:
            return 0;
    }
}

void android_main(struct android_app *app) {
    Engine *e = &g_engine;
    memset(e, 0, sizeof(*e));
    e->app = app;
    e->surface = EGL_NO_SURFACE;
    app->userData = e;
    app->onAppCmd = handle_cmd;
    app->onInputEvent = handle_input;

    if (app->activity->internalDataPath) {
        snprintf(e->data_dir, sizeof(e->data_dir), "%s", app->activity->internalDataPath);
    } else {
        snprintf(e->data_dir, sizeof(e->data_dir), "/data/local/tmp");
    }
    LOGI("启动，数据目录 %s", e->data_dir);

    if (!egl_init(e)) LOGE("EGL 初始化失败，界面无法显示");
    if (!audio_init(e)) LOGI("OpenSL ES 不可用，静音运行");

    while (1) {
        int events;
        struct android_poll_source *source;
        int timeout = (e->has_surface && e->cs_started && cs_wants_frame()) ? 16 : -1;
        while (ALooper_pollAll(timeout, NULL, &events, (void **)&source) >= 0) {
            if (source) source->process(app, source);
            if (app->destroyRequested) {
                surface_destroy(e);
                return;
            }
            timeout = 0;
        }
        if (e->has_surface && e->focused && e->cs_started) cs_frame();
    }
}
