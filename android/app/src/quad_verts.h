#include <stdio.h>
#include <string.h>
/* 一个矩形拆成两个三角形的顶点表。
   设备端（GL 顶点缓冲）与自检共用同一份，避免"主机侧用像素循环画、设备端用 GL 顶点画"
   两条路径各写一遍，导致顶点错误在主机自检里永远暴露不出来。 */
static inline void cs_quad_verts(float x, float y, float w, float h,
                                 float u0, float v0, float u1, float v1,
                                 float *xs, float *ys, float *us, float *vs) {
    xs[0] = x;     ys[0] = y;     us[0] = u0; vs[0] = v0; /* 左上 */
    xs[1] = x + w; ys[1] = y;     us[1] = u1; vs[1] = v0; /* 右上 */
    xs[2] = x;     ys[2] = y + h; us[2] = u0; vs[2] = v1; /* 左下 */
    xs[3] = x;     ys[3] = y + h; us[3] = u0; vs[3] = v1; /* 左下 */
    xs[4] = x + w; ys[4] = y + h; us[4] = u1; vs[4] = v1; /* 右下 */
    xs[5] = x + w; ys[5] = y;     us[5] = u1; vs[5] = v0; /* 右上 */
}

/* 自检：两个三角形都必须有非零面积，且每个顶点的 UV 必须与它的位置对应
   （左上=u0v0、右上=u1v0、左下=u0v1、右下=u1v1）。返回 0 通过，非 0 为错误码。 */
static inline int cs_quad_selftest(char *msg, int cap) {
    const float x = 100.0f, y = 50.0f, w = 60.0f, h = 24.0f;
    const float u0 = 0.25f, v0 = 0.75f, u1 = 0.3125f, v1 = 0.78125f;
    float xs[6], ys[6], us[6], vs[6];
    cs_quad_verts(x, y, w, h, u0, v0, u1, v1, xs, ys, us, vs);
    float a1 = (xs[1] - xs[0]) * (ys[2] - ys[0]) - (xs[2] - xs[0]) * (ys[1] - ys[0]);
    float a2 = (xs[4] - xs[3]) * (ys[5] - ys[3]) - (xs[5] - xs[3]) * (ys[4] - ys[3]);
    if (a1 == 0.0f || a2 == 0.0f) {
        snprintf(msg, cap, "矩形顶点退化：三角形面积 %.3f / %.3f（第二个三角形会被整块丢弃）", a1, a2);
        return 1;
    }
    for (int i = 0; i < 6; i++) {
        const char *want = NULL;
        if (xs[i] == x && ys[i] == y) want = "tl";
        else if (xs[i] == x + w && ys[i] == y) want = "tr";
        else if (xs[i] == x && ys[i] == y + h) want = "bl";
        else if (xs[i] == x + w && ys[i] == y + h) want = "br";
        int ok = 0;
        if (want == NULL) { ok = 0; }
        else if (!strcmp(want, "tl")) ok = (us[i] == u0 && vs[i] == v0);
        else if (!strcmp(want, "tr")) ok = (us[i] == u1 && vs[i] == v0);
        else if (!strcmp(want, "bl")) ok = (us[i] == u0 && vs[i] == v1);
        else ok = (us[i] == u1 && vs[i] == v1);
        if (!ok) {
            snprintf(msg, cap, "顶点 %d 的 UV 与位置不匹配：(%.0f,%.0f) uv=(%.4f,%.4f)", i, xs[i], ys[i], us[i], vs[i]);
            return 2;
        }
    }
    return 0;
}
