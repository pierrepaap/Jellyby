/*
 * cec-kbd: translate HDMI-CEC remote key presses into Linux keyboard events.
 *
 * Talks to the kernel CEC framework directly (/dev/cecN, <linux/cec.h>) — the
 * interface behind HDMI-CEC on the Raspberry Pi 4 under vc4-kms and on
 * Rockchip dw-hdmi (Radxa ZERO 3). No libcec: distro libcec builds often lack
 * the Linux CEC adapter, which would leave the remote dead.
 *
 * It claims a Playback logical address ("Jellyby") on every CEC adapter it
 * finds (the Pi 4 has one per HDMI port), answers the few messages TVs use to
 * decide where to route remote keys (power status, menu request, active
 * source / stream path), and re-injects User Control Pressed keys through
 * /dev/uinput so the kiosk browser and mpv see normal keyboard input.
 *
 * Key mapping is read from a simple config file, e.g.:
 *
 *   select = enter
 *   exit   = ctrl+w
 *
 * Usage: cec-kbd [keymap.conf] [/dev/cecN ...]
 *   Devices default to $CEC_KBD_PORT (space-separated) or all of /dev/cec0-3.
 *   CEC_KBD_ACTIVATE=1: wake the TV and switch it to this input at start.
 *
 * Build: gcc -O2 -Wall -o cec-kbd cec_kbd.c   (kernel headers only)
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/cec.h>
#include <linux/input-event-codes.h>
#include <linux/uinput.h>

struct key_name {
  const char *name;
  uint16_t code;
};

static const struct key_name KEY_NAMES[] = {
  {"enter", KEY_ENTER}, {"return", KEY_ENTER},
  {"esc", KEY_ESC}, {"escape", KEY_ESC},
  {"backspace", KEY_BACKSPACE}, {"space", KEY_SPACE}, {"tab", KEY_TAB},
  {"up", KEY_UP}, {"down", KEY_DOWN}, {"left", KEY_LEFT}, {"right", KEY_RIGHT},
  {"home", KEY_HOME}, {"end", KEY_END},
  {"pageup", KEY_PAGEUP}, {"pagedown", KEY_PAGEDOWN},
  {"insert", KEY_INSERT}, {"delete", KEY_DELETE},
  {"mute", KEY_MUTE}, {"volumeup", KEY_VOLUMEUP}, {"volumedown", KEY_VOLUMEDOWN},
  {"nextsong", KEY_NEXTSONG}, {"previoussong", KEY_PREVIOUSSONG},
  {"f1", KEY_F1}, {"f2", KEY_F2}, {"f3", KEY_F3}, {"f4", KEY_F4},
  {"f5", KEY_F5}, {"f6", KEY_F6}, {"f7", KEY_F7}, {"f8", KEY_F8},
  {"f9", KEY_F9}, {"f10", KEY_F10}, {"f11", KEY_F11}, {"f12", KEY_F12},
  {"0", KEY_0}, {"1", KEY_1}, {"2", KEY_2}, {"3", KEY_3}, {"4", KEY_4},
  {"5", KEY_5}, {"6", KEY_6}, {"7", KEY_7}, {"8", KEY_8}, {"9", KEY_9},
  {"a", KEY_A}, {"b", KEY_B}, {"c", KEY_C}, {"d", KEY_D}, {"e", KEY_E},
  {"f", KEY_F}, {"g", KEY_G}, {"h", KEY_H}, {"i", KEY_I}, {"j", KEY_J},
  {"k", KEY_K}, {"l", KEY_L}, {"m", KEY_M}, {"n", KEY_N}, {"o", KEY_O},
  {"p", KEY_P}, {"q", KEY_Q}, {"r", KEY_R}, {"s", KEY_S}, {"t", KEY_T},
  {"u", KEY_U}, {"v", KEY_V}, {"w", KEY_W}, {"x", KEY_X}, {"y", KEY_Y},
  {"z", KEY_Z},
  {"comma", KEY_COMMA}, {"dot", KEY_DOT}, {"period", KEY_DOT},
  {"minus", KEY_MINUS}, {"equal", KEY_EQUAL}, {"slash", KEY_SLASH},
  {"backslash", KEY_BACKSLASH}, {"semicolon", KEY_SEMICOLON},
  {"apostrophe", KEY_APOSTROPHE}, {"grave", KEY_GRAVE},
  {"leftbracket", KEY_LEFTBRACE}, {"rightbracket", KEY_RIGHTBRACE},
};

static const struct key_name MOD_NAMES[] = {
  {"ctrl", KEY_LEFTCTRL}, {"control", KEY_LEFTCTRL},
  {"alt", KEY_LEFTALT}, {"shift", KEY_LEFTSHIFT},
  {"meta", KEY_LEFTMETA}, {"super", KEY_LEFTMETA},
};

struct cec_name {
  const char *name;
  uint8_t code;
};

/* HDMI-CEC "UI command" codes (CEC 1.4 table 27); names match libcec's so
 * existing keymaps keep working. */
static const struct cec_name CEC_NAMES[] = {
  {"select", 0x00},
  {"up", 0x01},
  {"down", 0x02},
  {"left", 0x03},
  {"right", 0x04},
  {"right_up", 0x05},
  {"right_down", 0x06},
  {"left_up", 0x07},
  {"left_down", 0x08},
  {"root_menu", 0x09},
  {"setup_menu", 0x0a},
  {"contents_menu", 0x0b},
  {"favorite_menu", 0x0c},
  {"exit", 0x0d},
  {"top_menu", 0x10},
  {"dvd_menu", 0x11},
  {"number_entry_mode", 0x1d},
  {"number0", 0x20},
  {"number1", 0x21},
  {"number2", 0x22},
  {"number3", 0x23},
  {"number4", 0x24},
  {"number5", 0x25},
  {"number6", 0x26},
  {"number7", 0x27},
  {"number8", 0x28},
  {"number9", 0x29},
  {"number11", 0x1e},
  {"number12", 0x1f},
  {"dot", 0x2a},
  {"enter", 0x2b},
  {"clear", 0x2c},
  {"next_favorite", 0x2f},
  {"channel_up", 0x30},
  {"channel_down", 0x31},
  {"previous_channel", 0x32},
  {"sound_select", 0x33},
  {"input_select", 0x34},
  {"display_information", 0x35},
  {"help", 0x36},
  {"page_up", 0x37},
  {"page_down", 0x38},
  {"power", 0x40},
  {"volume_up", 0x41},
  {"volume_down", 0x42},
  {"mute", 0x43},
  {"play", 0x44},
  {"stop", 0x45},
  {"pause", 0x46},
  {"record", 0x47},
  {"rewind", 0x48},
  {"fast_forward", 0x49},
  {"eject", 0x4a},
  {"forward", 0x4b},
  {"backward", 0x4c},
  {"stop_record", 0x4d},
  {"pause_record", 0x4e},
  {"angle", 0x50},
  {"sub_picture", 0x51},
  {"video_on_demand", 0x52},
  {"epg", 0x53},
  {"timer_programming", 0x54},
  {"initial_configuration", 0x55},
  {"play_function", 0x60},
  {"pause_play_function", 0x61},
  {"stop_function", 0x64},
  {"mute_function", 0x65},
  {"power_toggle_function", 0x6b},
  {"power_off_function", 0x6c},
  {"power_on_function", 0x6d},
  {"f1_blue", 0x71},
  {"f2_red", 0x72},
  {"f3_green", 0x73},
  {"f4_yellow", 0x74},
  {"f5", 0x75},
  {"an_return", 0x91},
  {"an_channels_list", 0x96},
};

#define MAX_MAP 128
struct mapping {
  uint8_t code;
  char spec[64];
};
static struct mapping g_map[MAX_MAP];
static int g_map_len;

static int g_uinput = -1;
static volatile sig_atomic_t g_run = 1;

static uint16_t lookup_key(const char *name, const struct key_name *table, size_t n) {
  for (size_t i = 0; i < n; i++)
    if (strcmp(table[i].name, name) == 0)
      return table[i].code;
  return 0;
}

static int load_keymap(const char *path) {
  FILE *f = fopen(path, "r");
  if (!f)
    return -1;
  char line[256];
  while (fgets(line, sizeof line, f)) {
    char *hash = strchr(line, '#');
    if (hash)
      *hash = '\0';
    char *eq = strchr(line, '=');
    if (!eq)
      continue;
    *eq = '\0';
    char *name = line;
    char *spec = eq + 1;
    /* trim */
    char *p;
    while (*name == ' ' || *name == '\t') name++;
    p = name + strlen(name);
    while (p > name && (p[-1] == ' ' || p[-1] == '\t' || p[-1] == '\n' || p[-1] == '\r')) *--p = '\0';
    while (*spec == ' ' || *spec == '\t') spec++;
    p = spec + strlen(spec);
    while (p > spec && (p[-1] == ' ' || p[-1] == '\t' || p[-1] == '\n' || p[-1] == '\r')) *--p = '\0';
    if (!*name || !*spec)
      continue;
    int code = -1;
    size_t n = sizeof CEC_NAMES / sizeof CEC_NAMES[0];
    for (size_t i = 0; i < n; i++)
      if (strcmp(CEC_NAMES[i].name, name) == 0) {
        code = CEC_NAMES[i].code;
        break;
      }
    if (code < 0) {
      fprintf(stderr, "cec-kbd: unknown CEC button name '%s' in %s\n", name, path);
      continue;
    }
    if (g_map_len >= MAX_MAP)
      break;
    g_map[g_map_len].code = (uint8_t)code;
    snprintf(g_map[g_map_len].spec, sizeof g_map[g_map_len].spec, "%s", spec);
    g_map_len++;
  }
  fclose(f);
  return g_map_len > 0 ? 0 : -1;
}

static const char *find_spec(uint8_t code) {
  for (int i = 0; i < g_map_len; i++)
    if (g_map[i].code == code)
      return g_map[i].spec;
  return NULL;
}

static void emit(uint16_t type, uint16_t code, int32_t value) {
  struct input_event ev;
  memset(&ev, 0, sizeof ev);
  ev.type = type;
  ev.code = code;
  ev.value = value;
  if (write(g_uinput, &ev, sizeof ev) < 0) {
    /* best effort */
  }
}

static void syn(void) {
  emit(EV_SYN, SYN_REPORT, 0);
}

static void tap_spec(const char *spec) {
  char buf[64];
  snprintf(buf, sizeof buf, "%s", spec);
  uint16_t mods[8];
  int nmods = 0;
  uint16_t key = 0;
  char *save = NULL;
  for (char *tok = strtok_r(buf, "+", &save); tok; tok = strtok_r(NULL, "+", &save)) {
    uint16_t m = lookup_key(tok, MOD_NAMES, sizeof MOD_NAMES / sizeof MOD_NAMES[0]);
    if (m) {
      if (nmods < 8)
        mods[nmods++] = m;
      continue;
    }
    key = lookup_key(tok, KEY_NAMES, sizeof KEY_NAMES / sizeof KEY_NAMES[0]);
  }
  if (!key) {
    fprintf(stderr, "cec-kbd: bad key spec '%s'\n", spec);
    return;
  }
  for (int i = 0; i < nmods; i++)
    emit(EV_KEY, mods[i], 1);
  emit(EV_KEY, key, 1);
  syn();
  emit(EV_KEY, key, 0);
  for (int i = nmods - 1; i >= 0; i--)
    emit(EV_KEY, mods[i], 0);
  syn();
}

static int uinput_init(void) {
  int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
  if (fd < 0)
    return -1;
  if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0)
    goto fail;
  size_t nk = sizeof KEY_NAMES / sizeof KEY_NAMES[0];
  for (size_t i = 0; i < nk; i++)
    ioctl(fd, UI_SET_KEYBIT, KEY_NAMES[i].code);
  size_t nm = sizeof MOD_NAMES / sizeof MOD_NAMES[0];
  for (size_t i = 0; i < nm; i++)
    ioctl(fd, UI_SET_KEYBIT, MOD_NAMES[i].code);
  struct uinput_setup setup;
  memset(&setup, 0, sizeof setup);
  setup.id.bustype = BUS_USB;
  setup.id.vendor = 0x1209;
  setup.id.product = 0x4a42;
  snprintf(setup.name, sizeof setup.name, "Jellyby CEC keyboard");
  if (ioctl(fd, UI_DEV_SETUP, &setup) < 0)
    goto fail;
  if (ioctl(fd, UI_DEV_CREATE) < 0)
    goto fail;
  g_uinput = fd;
  return 0;
fail:
  close(fd);
  return -1;
}

/* ---------------------------------------------------------------- CEC -- */

#define MAX_ADAPTERS 4
#define OP_FEATURE_ABORT          0x00
#define OP_IMAGE_VIEW_ON          0x04
#define OP_USER_CONTROL_PRESSED   0x44
#define OP_USER_CONTROL_RELEASED  0x45
#define OP_GIVE_OSD_NAME          0x46
#define OP_SET_OSD_NAME           0x47
#define OP_ROUTING_CHANGE         0x80
#define OP_ROUTING_INFORMATION    0x81
#define OP_ACTIVE_SOURCE          0x82
#define OP_REQUEST_ACTIVE_SOURCE  0x85
#define OP_SET_STREAM_PATH        0x86
#define OP_MENU_REQUEST           0x8D
#define OP_MENU_STATUS            0x8E
#define OP_GIVE_POWER_STATUS      0x8F
#define OP_REPORT_POWER_STATUS    0x90
#define LA_TV        0x0
#define LA_BROADCAST 0xF

struct adapter {
  int fd;
  char path[32];
  uint16_t pa;       /* physical address, CEC_PHYS_ADDR_INVALID if unplugged */
  uint8_t la;        /* our logical address, CEC_LOG_ADDR_INVALID until claimed */
  bool active;       /* we believe we are the active source on this link */
  bool activated;    /* CEC_KBD_ACTIVATE already done for this PA */
};

static struct adapter g_ad[MAX_ADAPTERS];
static int g_nad;
static bool g_activate;

static void cec_send(struct adapter *a, uint8_t to, const uint8_t *data, int len) {
  if (a->la == CEC_LOG_ADDR_INVALID || len < 1 || len > 15)
    return;
  struct cec_msg m;
  memset(&m, 0, sizeof m);
  m.msg[0] = (uint8_t)((a->la << 4) | (to & 0xf));
  memcpy(&m.msg[1], data, (size_t)len);
  m.len = (uint32_t)len + 1;
  if (ioctl(a->fd, CEC_TRANSMIT, &m) < 0 && errno != EAGAIN)
    fprintf(stderr, "cec-kbd: %s: transmit 0x%02x failed: %s\n", a->path, data[0], strerror(errno));
}

static void announce_active(struct adapter *a) {
  if (a->pa == CEC_PHYS_ADDR_INVALID)
    return;
  uint8_t d[3] = {OP_ACTIVE_SOURCE, (uint8_t)(a->pa >> 8), (uint8_t)(a->pa & 0xff)};
  cec_send(a, LA_BROADCAST, d, 3);
  a->active = true;
}

static void refresh_state(struct adapter *a) {
  uint16_t pa = CEC_PHYS_ADDR_INVALID;
  if (ioctl(a->fd, CEC_ADAP_G_PHYS_ADDR, &pa) == 0)
    a->pa = pa;
  struct cec_log_addrs l;
  memset(&l, 0, sizeof l);
  a->la = CEC_LOG_ADDR_INVALID;
  if (ioctl(a->fd, CEC_ADAP_G_LOG_ADDRS, &l) == 0 && l.num_log_addrs > 0 &&
      l.log_addr[0] != CEC_LOG_ADDR_INVALID)
    a->la = l.log_addr[0];
  if (a->pa == CEC_PHYS_ADDR_INVALID) {
    a->active = false;
    a->activated = false;
  }
  fprintf(stderr, "cec-kbd: %s: physical address %x.%x.%x.%x, logical address %d\n", a->path,
          a->pa >> 12, (a->pa >> 8) & 0xf, (a->pa >> 4) & 0xf, a->pa & 0xf,
          a->la == CEC_LOG_ADDR_INVALID ? -1 : a->la);
  if (g_activate && !a->activated && a->pa != CEC_PHYS_ADDR_INVALID && a->la != CEC_LOG_ADDR_INVALID) {
    uint8_t ivo = OP_IMAGE_VIEW_ON;
    cec_send(a, LA_TV, &ivo, 1);
    announce_active(a);
    a->activated = true;
  }
}

static int adapter_open(const char *path) {
  if (g_nad >= MAX_ADAPTERS)
    return -1;
  int fd = open(path, O_RDWR | O_NONBLOCK);
  if (fd < 0)
    return -1;
  struct adapter *a = &g_ad[g_nad];
  memset(a, 0, sizeof *a);
  a->fd = fd;
  a->pa = CEC_PHYS_ADDR_INVALID;
  a->la = CEC_LOG_ADDR_INVALID;
  snprintf(a->path, sizeof a->path, "%s", path);

  struct cec_caps caps;
  memset(&caps, 0, sizeof caps);
  if (ioctl(fd, CEC_ADAP_G_CAPS, &caps) < 0) {
    fprintf(stderr, "cec-kbd: %s: not a CEC adapter: %s\n", path, strerror(errno));
    close(fd);
    return -1;
  }
  uint32_t mode = CEC_MODE_INITIATOR | CEC_MODE_FOLLOWER;
  if (ioctl(fd, CEC_S_MODE, &mode) < 0) {
    fprintf(stderr, "cec-kbd: %s: cannot become follower: %s\n", path, strerror(errno));
    close(fd);
    return -1;
  }
  if (caps.capabilities & CEC_CAP_LOG_ADDRS) {
    struct cec_log_addrs l;
    memset(&l, 0, sizeof l);
    ioctl(fd, CEC_ADAP_S_LOG_ADDRS, &l); /* clear any previous claim */
    l.cec_version = CEC_OP_CEC_VERSION_1_4;
    l.vendor_id = CEC_VENDOR_ID_NONE;
    l.flags = CEC_LOG_ADDRS_FL_ALLOW_UNREG_FALLBACK;
    snprintf(l.osd_name, sizeof l.osd_name, "Jellyby");
    l.num_log_addrs = 1;
    l.log_addr_type[0] = CEC_LOG_ADDR_TYPE_PLAYBACK;
    l.primary_device_type[0] = CEC_OP_PRIM_DEVTYPE_PLAYBACK;
    l.all_device_types[0] = CEC_OP_ALL_DEVTYPE_PLAYBACK;
    if (ioctl(fd, CEC_ADAP_S_LOG_ADDRS, &l) < 0)
      fprintf(stderr, "cec-kbd: %s: claiming a playback address failed: %s\n", path, strerror(errno));
  }
  fprintf(stderr, "cec-kbd: opened %s (%s)\n", path, caps.driver);
  g_nad++;
  refresh_state(a);
  return 0;
}

static void handle_msg(struct adapter *a, const struct cec_msg *m) {
  if (m->len < 2)
    return; /* poll message */
  uint8_t from = m->msg[0] >> 4;
  uint8_t op = m->msg[1];
  uint16_t pa_arg = m->len >= 4 ? (uint16_t)((m->msg[2] << 8) | m->msg[3]) : 0;

  switch (op) {
  case OP_USER_CONTROL_PRESSED: {
    if (m->len < 3)
      return;
    uint8_t code = m->msg[2];
    const char *spec = find_spec(code);
    if (!spec) {
      fprintf(stderr, "cec-kbd: unmapped CEC key 0x%02x\n", code);
      return;
    }
    fprintf(stderr, "cec-kbd: CEC key 0x%02x -> %s\n", code, spec);
    tap_spec(spec);
    return;
  }
  case OP_USER_CONTROL_RELEASED:
    return;
  case OP_GIVE_POWER_STATUS: {
    uint8_t d[2] = {OP_REPORT_POWER_STATUS, 0x00 /* on */};
    cec_send(a, from, d, 2);
    return;
  }
  case OP_MENU_REQUEST: {
    uint8_t d[2] = {OP_MENU_STATUS, 0x00 /* activated: send us the keys */};
    cec_send(a, from, d, 2);
    return;
  }
  case OP_GIVE_OSD_NAME: {
    uint8_t d[8] = {OP_SET_OSD_NAME, 'J', 'e', 'l', 'l', 'y', 'b', 'y'};
    cec_send(a, from, d, 8);
    return;
  }
  case OP_SET_STREAM_PATH:
  case OP_ROUTING_INFORMATION:
    if (m->len >= 4 && pa_arg == a->pa)
      announce_active(a);
    return;
  case OP_ROUTING_CHANGE:
    if (m->len >= 6) {
      uint16_t to_pa = (uint16_t)((m->msg[4] << 8) | m->msg[5]);
      if (to_pa == a->pa)
        announce_active(a);
      else
        a->active = false;
    }
    return;
  case OP_REQUEST_ACTIVE_SOURCE:
    if (a->active)
      announce_active(a);
    return;
  case OP_ACTIVE_SOURCE:
    if (from != a->la)
      a->active = false;
    return;
  default:
    return;
  }
}

static void on_signal(int sig) {
  (void)sig;
  g_run = 0;
}

int main(int argc, char **argv) {
  const char *conf = argc > 1 ? argv[1] : "/etc/jellyby/cec-keymap.conf";
  if (load_keymap(conf) < 0) {
    fprintf(stderr, "cec-kbd: cannot load keymap from %s\n", conf);
    return 1;
  }
  fprintf(stderr, "cec-kbd: loaded %d mappings from %s\n", g_map_len, conf);
  const char *act = getenv("CEC_KBD_ACTIVATE");
  g_activate = act && strcmp(act, "1") == 0;

  if (uinput_init() < 0) {
    fprintf(stderr, "cec-kbd: cannot create uinput device: %s\n", strerror(errno));
    return 1;
  }

  if (argc > 2) {
    for (int i = 2; i < argc; i++)
      adapter_open(argv[i]);
  } else if (getenv("CEC_KBD_PORT") && *getenv("CEC_KBD_PORT")) {
    char buf[256];
    snprintf(buf, sizeof buf, "%s", getenv("CEC_KBD_PORT"));
    char *save = NULL;
    for (char *tok = strtok_r(buf, " ,", &save); tok; tok = strtok_r(NULL, " ,", &save))
      adapter_open(tok);
  } else {
    char path[32];
    for (int i = 0; i < MAX_ADAPTERS; i++) {
      snprintf(path, sizeof path, "/dev/cec%d", i);
      if (access(path, F_OK) == 0)
        adapter_open(path);
    }
  }
  if (g_nad == 0) {
    /* exit non-zero: systemd restarts us (the CEC device may appear late) */
    fprintf(stderr, "cec-kbd: no usable CEC adapter (/dev/cec*); is HDMI-CEC enabled in the device tree?\n");
    close(g_uinput);
    return 1;
  }

  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = on_signal;
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGINT, &sa, NULL);
  fprintf(stderr, "cec-kbd: listening for CEC key presses on %d adapter(s)\n", g_nad);

  struct pollfd pfd[MAX_ADAPTERS];
  while (g_run) {
    for (int i = 0; i < g_nad; i++) {
      pfd[i].fd = g_ad[i].fd;
      pfd[i].events = POLLIN | POLLPRI;
      pfd[i].revents = 0;
    }
    int n = poll(pfd, (nfds_t)g_nad, 1000);
    if (n < 0) {
      if (errno == EINTR)
        continue;
      fprintf(stderr, "cec-kbd: poll: %s\n", strerror(errno));
      break;
    }
    for (int i = 0; i < g_nad; i++) {
      struct adapter *a = &g_ad[i];
      if (pfd[i].revents & POLLPRI) {
        struct cec_event ev;
        memset(&ev, 0, sizeof ev);
        while (ioctl(a->fd, CEC_DQEVENT, &ev) == 0) {
          if (ev.event == CEC_EVENT_STATE_CHANGE)
            refresh_state(a);
          else if (ev.event == CEC_EVENT_LOST_MSGS)
            fprintf(stderr, "cec-kbd: %s: lost %u messages\n", a->path, ev.lost_msgs.lost_msgs);
          memset(&ev, 0, sizeof ev);
        }
      }
      if (pfd[i].revents & POLLIN) {
        struct cec_msg m;
        memset(&m, 0, sizeof m);
        while (ioctl(a->fd, CEC_RECEIVE, &m) == 0) {
          handle_msg(a, &m);
          memset(&m, 0, sizeof m);
        }
      }
      if (pfd[i].revents & (POLLERR | POLLHUP | POLLNVAL)) {
        fprintf(stderr, "cec-kbd: %s: device error, exiting for a restart\n", a->path);
        g_run = 0;
      }
    }
  }

  for (int i = 0; i < g_nad; i++)
    close(g_ad[i].fd);
  close(g_uinput);
  fprintf(stderr, "cec-kbd: stopped\n");
  return g_run ? 1 : 0;
}
