// Drive the app's swapped Mpv.framework the way media_kit does: dlopen + client API.
// Deliberately NOT linked against libmpv, so the only mpv in the process is the
// framework under test.
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct mpv_handle mpv_handle;
typedef struct mpv_event {
  int event_id;
  int error;
  unsigned long long reply_userdata;
  void *data;
} mpv_event;
#define MPV_EVENT_NONE 0
#define MPV_EVENT_FILE_LOADED 8
#define MPV_EVENT_END_FILE 7

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

  const char *syms[] = {"mpv_create", "mpv_initialize", "mpv_set_option_string",
                        "mpv_command", "mpv_get_property_string", "mpv_wait_event",
                        "mpv_observe_property", "mpv_render_context_create",
                        "mpv_render_context_render", "mpv_render_context_update",
                        "mpv_client_api_version", NULL};
  int missing = 0;
  for (int i = 0; syms[i]; i++)
    if (!dlsym(h, syms[i])) { printf("  MISSING SYMBOL: %s\n", syms[i]); missing++; }
  printf("media_kit-required symbols present: %s\n", missing ? "NO" : "yes");

  unsigned long (*api_version)(void) = dlsym(h, "mpv_client_api_version");
  unsigned long v = api_version();
  printf("mpv client API version: %lu.%lu\n", v >> 16, v & 0xFFFF);

  mpv_handle *(*create)(void) = dlsym(h, "mpv_create");
  int (*init)(mpv_handle *) = dlsym(h, "mpv_initialize");
  int (*setopt)(mpv_handle *, const char *, const char *) = dlsym(h, "mpv_set_option_string");
  int (*cmd)(mpv_handle *, const char **) = dlsym(h, "mpv_command");
  char *(*getprop)(mpv_handle *, const char *) = dlsym(h, "mpv_get_property_string");
  mpv_event *(*wait_event)(mpv_handle *, double) = dlsym(h, "mpv_wait_event");

  mpv_handle *mpv = create();
  if (!mpv) { printf("mpv_create FAILED\n"); return 1; }
  setopt(mpv, "config", "no");
  setopt(mpv, "load-scripts", "no");
  setopt(mpv, "hwdec", "auto");
  setopt(mpv, "vo", "null");
  setopt(mpv, "ao", "null");
  printf("mpv_initialize: %d\n", init(mpv));

  const char *cmdline[] = {"loadfile", file, NULL};
  cmd(mpv, cmdline);

  int loaded = 0;
  for (int i = 0; i < 100 && !loaded; i++) {
    mpv_event *e = wait_event(mpv, 0.1);
    if (e && (e->event_id == MPV_EVENT_FILE_LOADED || e->event_id == MPV_EVENT_END_FILE))
      loaded = e->event_id;
  }
  printf("file-loaded event: %s\n",
         loaded == MPV_EVENT_FILE_LOADED ? "yes" : (loaded ? "ended prematurely" : "timeout"));

  sleep(3); // let it decode a while, then read state *while playing*
  printf("mpv-version:   %s\n", getprop(mpv, "mpv-version"));
  printf("video-codec:   %s\n", getprop(mpv, "video-codec"));
  printf("hwdec:         %s\n", getprop(mpv, "hwdec"));
  printf("hwdec-current: %s\n", getprop(mpv, "hwdec-current"));
  return 0;
}
