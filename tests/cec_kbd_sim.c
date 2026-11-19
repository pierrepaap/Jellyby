/*
 * Hardware-free test for files/opt/jellyby/cec_kbd.c.
 *
 * Links a fake kernel CEC adapter (/dev/cec0) and a fake /dev/uinput into the
 * daemon by overriding open/ioctl/poll/write, replays what a TV sends, and
 * checks what cec-kbd transmits back and which keys it types.
 *
 *   gcc -Wall -o /tmp/cec_kbd_sim tests/cec_kbd_sim.c && /tmp/cec_kbd_sim files/etc/jellyby/cec-keymap.conf
 */
#include <stdarg.h>
#define main cec_kbd_main
#include "../files/opt/jellyby/cec_kbd.c"
#undef main

#define CEC_FD 100
#define UI_FD 200
static struct cec_msg rxq[32];
static int rxn, rxi, polls, claimed, event_pending = 1;
static struct cec_log_addrs cur_la;
static char tx_log[2048];  /* "40 90 00|4f 82 10 00|..." */
static char key_log[1024]; /* "28+ 28- 29+ ..." */
static int failures;

static void rx(const char *hex) {
  struct cec_msg *m = &rxq[rxn++];
  memset(m, 0, sizeof *m);
  unsigned v; int n = 0;
  for (const char *p = hex; sscanf(p, "%x%n", &v, &n) == 1; p += n)
    m->msg[m->len++] = (uint8_t)v;
}
static void expect(const char *what, const char *log, const char *needle) {
  if (!strstr(log, needle)) {
    fprintf(stderr, "FAIL: %s: expected '%s' in '%s'\n", what, needle, log);
    failures++;
  } else {
    fprintf(stderr, "ok: %s\n", what);
  }
}

int access(const char *path, int mode) { (void)mode; return strcmp(path, "/dev/cec0") ? -1 : 0; }
int open(const char *path, int flags, ...) {
  (void)flags;
  if (!strcmp(path, "/dev/cec0")) return CEC_FD;
  if (!strcmp(path, "/dev/uinput")) return UI_FD;
  errno = ENOENT;
  return -1;
}
int close(int fd) { (void)fd; return 0; }
ssize_t write(int fd, const void *buf, size_t n) {
  const struct input_event *e = buf;
  if (fd == UI_FD && e->type == EV_KEY) {
    char t[16];
    snprintf(t, sizeof t, "%u%c ", e->code, e->value ? '+' : '-');
    strncat(key_log, t, sizeof key_log - strlen(key_log) - 1);
  }
  return (ssize_t)n;
}
int ioctl(int fd, unsigned long req, ...) {
  va_list ap; va_start(ap, req); void *arg = va_arg(ap, void *); va_end(ap);
  if (fd == UI_FD) return 0;
  switch (req) {
  case CEC_ADAP_G_CAPS: {
    struct cec_caps *c = arg;
    snprintf(c->driver, sizeof c->driver, "fake");
    c->capabilities = CEC_CAP_LOG_ADDRS | CEC_CAP_TRANSMIT;
    return 0;
  }
  case CEC_S_MODE: return 0;
  case CEC_ADAP_S_LOG_ADDRS: cur_la = *(struct cec_log_addrs *)arg; return 0;
  case CEC_ADAP_G_LOG_ADDRS: {
    struct cec_log_addrs *l = arg;
    *l = cur_la;
    l->log_addr[0] = claimed ? 4 : CEC_LOG_ADDR_INVALID;
    return 0;
  }
  case CEC_ADAP_G_PHYS_ADDR: *(uint16_t *)arg = claimed ? 0x1000 : CEC_PHYS_ADDR_INVALID; return 0;
  case CEC_DQEVENT:
    if (event_pending) { /* HDMI plugged, address claimed */
      event_pending = 0; claimed = 1;
      ((struct cec_event *)arg)->event = CEC_EVENT_STATE_CHANGE;
      return 0;
    }
    errno = EAGAIN; return -1;
  case CEC_RECEIVE:
    if (rxi < rxn) { *(struct cec_msg *)arg = rxq[rxi++]; return 0; }
    errno = EAGAIN; return -1;
  case CEC_TRANSMIT: {
    struct cec_msg *m = arg;
    for (unsigned i = 0; i < m->len; i++) {
      char t[4];
      snprintf(t, sizeof t, i ? " %02x" : "%02x", m->msg[i]);
      strncat(tx_log, t, sizeof tx_log - strlen(tx_log) - 1);
    }
    strncat(tx_log, "|", sizeof tx_log - strlen(tx_log) - 1);
    return 0;
  }
  }
  errno = ENOTTY;
  return -1;
}
int poll(struct pollfd *p, nfds_t n, int t) {
  (void)n; (void)t;
  if (polls++ == 0) { p[0].revents = POLLPRI | POLLIN; return 1; }
  g_run = 0;
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s <keymap>\n", argv[0]); return 2; }
  rx("04 8f");          /* TV: give power status */
  rx("04 8d 00");       /* TV: menu request */
  rx("04 46");          /* TV: give OSD name */
  rx("0f 86 10 00");    /* TV: set stream path -> 1.0.0.0 (us) */
  rx("0f 85");          /* TV: request active source */
  rx("04 44 00");       /* select */
  rx("04 45");          /* release */
  rx("04 44 0d");       /* exit */
  rx("04 44 25");       /* number5 */
  rx("04 44 77");       /* unmapped */
  char *args[] = {"cec-kbd", argv[1], NULL};
  int rc = cec_kbd_main(2, args);

  if (rc != 0) { fprintf(stderr, "FAIL: exit code %d\n", rc); failures++; }
  if (cur_la.log_addr_type[0] != CEC_LOG_ADDR_TYPE_PLAYBACK || strcmp(cur_la.osd_name, "Jellyby")) {
    fprintf(stderr, "FAIL: did not claim a Playback address named Jellyby\n"); failures++;
  } else {
    fprintf(stderr, "ok: claims Playback device 'Jellyby'\n");
  }
  expect("reports power on", tx_log, "40 90 00|");
  expect("menu status activated", tx_log, "40 8e 00|");
  expect("answers OSD name", tx_log, "40 47 4a 65 6c 6c 79 62 79|");
  expect("active source after set stream path", tx_log, "4f 82 10 00|4f 82 10 00|");
  expect("select -> enter", key_log, "28+ 28- ");
  expect("exit -> ctrl+w", key_log, "29+ 17+ 17- 29- ");
  expect("number5 -> 5", key_log, "6+ 6- ");
  if (failures) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
  fprintf(stderr, "cec-kbd simulation: all checks passed\n");
  return 0;
}
