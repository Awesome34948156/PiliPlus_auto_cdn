// Does the relinked dylib drive media_kit's *actual* macOS render path?
// mpvtest.c used vo=null, which never touches vo=libmpv. This one sets up a CGL
// context and the OpenGL render API exactly like media_kit's TextureHW does
// (MPV_RENDER_API_TYPE_OPENGL, no MPV_RENDER_PARAM_HW_FRAMES), renders into an
// FBO, and reads a pixel back to prove a real decoded frame landed there.
#define GL_SILENCE_DEPRECATION 1
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>

#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define LOAD(name) dlsym(h, name)
static void *get_proc_address(void *ctx, const char *name) {
  (void)ctx;
  return dlsym(RTLD_DEFAULT, name);
}

int main(int argc, char **argv) {
  const char *lib = argc > 2 ? argv[2] : "Mpv.framework/Versions/A/Mpv";
  if (argc < 2) {
    fprintf(stderr, "usage: %s <media-file> [dylib]\n", argv[0]);
    return 2;
  }
  const char *file = argv[1];

  void *h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
  if (!h) { fprintf(stderr, "dlopen FAILED: %s\n", dlerror()); return 1; }
  printf("dlopen OK: %s\n", lib);

  mpv_handle *(*p_create)(void) = LOAD("mpv_create");
  int (*p_init)(mpv_handle *) = LOAD("mpv_initialize");
  int (*p_setopt)(mpv_handle *, const char *, const char *) = LOAD("mpv_set_option_string");
  int (*p_cmd)(mpv_handle *, const char **) = LOAD("mpv_command");
  char *(*p_getstr)(mpv_handle *, const char *) = LOAD("mpv_get_property_string");
  mpv_event *(*p_wait)(mpv_handle *, double) = LOAD("mpv_wait_event");
  const char *(*p_errstr)(int) = LOAD("mpv_error_string");
  int (*p_rcreate)(mpv_render_context **, mpv_handle *, mpv_render_param *) =
      LOAD("mpv_render_context_create");
  unsigned long long (*p_rupdate)(mpv_render_context *) =
      LOAD("mpv_render_context_update");
  int (*p_rrender)(mpv_render_context *, mpv_render_param *) =
      LOAD("mpv_render_context_render");

  if (!p_create || !p_rcreate || !p_rrender || !p_errstr) {
    fprintf(stderr, "missing required mpv symbols\n");
    return 1;
  }
  const char *(*p_clientver)(void) = LOAD("mpv_client_api_version");
  (void)p_clientver;

  // ---- CGL 3.2 core context, the macOS requirement for the GL render API ----
  CGLPixelFormatAttribute attrs[] = {
      kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
      kCGLPFAAccelerated, (CGLPixelFormatAttribute)0};
  CGLPixelFormatObj pix = NULL;
  GLint npix = 0;
  CGLError cerr = CGLChoosePixelFormat(attrs, &pix, &npix);
  if (cerr != kCGLNoError) { fprintf(stderr, "CGLChoosePixelFormat: %d\n", cerr); return 1; }
  CGLContextObj ctx = NULL;
  if ((cerr = CGLCreateContext(pix, NULL, &ctx)) != kCGLNoError) {
    fprintf(stderr, "CGLCreateContext: %d\n", cerr);
    return 1;
  }
  CGLSetCurrentContext(ctx);
  printf("CGL context: OK (%s)\n", glGetString(GL_VERSION));

  // ---- mpv, configured the way media_kit configures it ----
  mpv_handle *mpv = p_create();
  if (!mpv) { fprintf(stderr, "mpv_create failed\n"); return 1; }
  p_setopt(mpv, "config", "no");
  p_setopt(mpv, "load-scripts", "no");
  p_setopt(mpv, "terminal", "no");
  p_setopt(mpv, "vo", "libmpv");        // <- media_kit's VO; the thing vo=null skipped
  p_setopt(mpv, "hwdec", "auto");
  p_setopt(mpv, "ao", "null");
  int r = p_init(mpv);
  printf("mpv_initialize: %d\n", r);
  if (r < 0) return 1;

  mpv_opengl_init_params glp = {get_proc_address, NULL};
  mpv_render_param rparams[] = {
      {MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL},
      {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &glp},
      {0, NULL}};
  mpv_render_context *rc = NULL;
  r = p_rcreate(&rc, mpv, rparams);
  printf("mpv_render_context_create(OPENGL): %d (%s)\n", r,
         r < 0 ? p_errstr(r) : "ok");
  if (r < 0) return 1;

  const char *cmd[] = {"loadfile", file, NULL};
  p_cmd(mpv, cmd);

  int loaded = 0, rendered = 0, render_err = 0;
  double w = 0, hgt = 0;
  GLuint fbo = 0, tex = 0;
  char *dws = NULL, *dhs = NULL;

  struct timespec t0, now;
  clock_gettime(CLOCK_MONOTONIC, &t0);
  for (;;) {
    clock_gettime(CLOCK_MONOTONIC, &now);
    if (now.tv_sec - t0.tv_sec > 8) break;

    mpv_event *e = p_wait(mpv, 0.01);
    if (e && e->event_id == MPV_EVENT_FILE_LOADED) loaded = 1;

    if (!rendered && loaded && !dws) {
      dws = p_getstr(mpv, "dwidth");
      dhs = p_getstr(mpv, "dheight");
      w = dws ? atof(dws) : 1920;
      hgt = dhs ? atof(dhs) : 1080;
      if (w <= 0) w = 1920;
      if (hgt <= 0) hgt = 1080;
      glGenTextures(1, &tex);
      glBindTexture(GL_TEXTURE_2D, tex);
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, (GLsizei)w, (GLsizei)hgt, 0, GL_RGBA,
                   GL_UNSIGNED_BYTE, NULL);
      glGenFramebuffers(1, &fbo);
      glBindFramebuffer(GL_FRAMEBUFFER, fbo);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
      GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
      printf("offscreen FBO %.0fx%.0f: %s\n", w, hgt,
             st == GL_FRAMEBUFFER_COMPLETE ? "complete" : "INCOMPLETE");
    }

    unsigned long long flags = rc ? p_rupdate(rc) : 0;
    if (rc && (flags & MPV_RENDER_UPDATE_FRAME) && fbo) {
      mpv_opengl_fbo ofbo = {(int)fbo, (int)w, (int)hgt, GL_RGBA8};
      int flip = 1;
      mpv_render_param rp[] = {{MPV_RENDER_PARAM_OPENGL_FBO, &ofbo},
                               {MPV_RENDER_PARAM_FLIP_Y, &flip},
                               {0, NULL}};
      int rr = p_rrender(rc, rp);
      if (rr < 0) {
        if (!render_err) printf("mpv_render_context_render FAILED: %d (%s)\n", rr, p_errstr(rr));
        render_err++;
      } else {
        rendered++;
      }
      if (rendered >= 30) break;
    }
  }

  printf("file-loaded event: %s\n", loaded ? "yes" : "NO");
  printf("frames rendered through vo=libmpv + GL render API: %d (errors: %d)\n", rendered,
         render_err);

  // Prove a decoded frame really landed: read the middle pixel back.
  int nonblack = 0;
  if (rendered > 0) {
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    unsigned char px[4] = {0, 0, 0, 0};
    glReadPixels((int)w / 2, (int)hgt / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    nonblack = (px[0] | px[1] | px[2]) != 0;
    printf("centre pixel readback: R=%u G=%u B=%u A=%u  (%s)\n", px[0], px[1], px[2], px[3],
           nonblack ? "non-black -> real frame" : "BLACK");
  }
  char *hwdec_cur = p_getstr(mpv, "hwdec-current");
  printf("video-codec:   %s\n", p_getstr(mpv, "video-codec"));
  printf("video-format:  %s\n", p_getstr(mpv, "video-format"));
  printf("hwdec:         %s\n", p_getstr(mpv, "hwdec"));
  printf("hwdec-current: %s\n", hwdec_cur);

  // The verdict is all three of README's criteria, not just "rendered some
  // frames": a silent fall back to libdav1d renders clean, non-black frames
  // too, so a frames-only exit code would pass and hide the exact bug this
  // check exists to catch. Demand hwdec-current == videotoolbox (the zero-copy
  // decoder -- mpvtest.c's copy-back reports videotoolbox-copy and must not pass).
  int hw_ok = hwdec_cur && strcmp(hwdec_cur, "videotoolbox") == 0;
  if (!hw_ok)
    fprintf(stderr, "hwdec-current: %s (expected videotoolbox)\n",
            hwdec_cur ? hwdec_cur : "(null)");
  return (rendered > 0 && render_err == 0 && nonblack && hw_ok) ? 0 : 1;
}
