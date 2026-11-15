/*
 * cec-kbd: translate HDMI-CEC remote key presses into Linux keyboard events.
 *
 * Uses libcec (C API) to listen for user-control key presses from the TV /
 * projector remote and re-injects them through /dev/uinput so that any
 * application (here: the Chromium kiosk) receives them as normal keyboard
 * input. Key mapping is read from a simple config file, e.g.:
 *
 *   select = enter
 *   exit   = ctrl+w
 *
 * Build: gcc -O2 -o cec-kbd cec_kbd.c $(pkg-config --cflags --libs libcec)
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/input-event-codes.h>
#include <linux/uinput.h>

/* header layout differs by distro: Debian/Raspberry Pi OS uses
 * /usr/include/cec/, Ubuntu uses /usr/include/libcec/, and pkg-config may
 * point directly at the header dir */
#if defined(__has_include)
#  if __has_include(<cec/cecc.h>)
#    include <cec/cecc.h>
#  elif __has_include(<libcec/cecc.h>)
#    include <libcec/cecc.h>
#  elif __has_include(<cecc.h>)
#    include <cecc.h>
#  else
#    error "libcec headers not found (install libcec-dev)"
#  endif
#else
#  include <cecc.h>
#endif

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
  cec_user_control_code code;
};

static const struct cec_name CEC_NAMES[] = {
  {"select", CEC_USER_CONTROL_CODE_SELECT},
  {"up", CEC_USER_CONTROL_CODE_UP},
  {"down", CEC_USER_CONTROL_CODE_DOWN},
  {"left", CEC_USER_CONTROL_CODE_LEFT},
  {"right", CEC_USER_CONTROL_CODE_RIGHT},
  {"right_up", CEC_USER_CONTROL_CODE_RIGHT_UP},
  {"right_down", CEC_USER_CONTROL_CODE_RIGHT_DOWN},
  {"left_up", CEC_USER_CONTROL_CODE_LEFT_UP},
  {"left_down", CEC_USER_CONTROL_CODE_LEFT_DOWN},
  {"root_menu", CEC_USER_CONTROL_CODE_ROOT_MENU},
  {"setup_menu", CEC_USER_CONTROL_CODE_SETUP_MENU},
  {"contents_menu", CEC_USER_CONTROL_CODE_CONTENTS_MENU},
  {"favorite_menu", CEC_USER_CONTROL_CODE_FAVORITE_MENU},
  {"exit", CEC_USER_CONTROL_CODE_EXIT},
  {"top_menu", CEC_USER_CONTROL_CODE_TOP_MENU},
  {"dvd_menu", CEC_USER_CONTROL_CODE_DVD_MENU},
  {"number_entry_mode", CEC_USER_CONTROL_CODE_NUMBER_ENTRY_MODE},
  {"number0", CEC_USER_CONTROL_CODE_NUMBER0},
  {"number1", CEC_USER_CONTROL_CODE_NUMBER1},
  {"number2", CEC_USER_CONTROL_CODE_NUMBER2},
  {"number3", CEC_USER_CONTROL_CODE_NUMBER3},
  {"number4", CEC_USER_CONTROL_CODE_NUMBER4},
  {"number5", CEC_USER_CONTROL_CODE_NUMBER5},
  {"number6", CEC_USER_CONTROL_CODE_NUMBER6},
  {"number7", CEC_USER_CONTROL_CODE_NUMBER7},
  {"number8", CEC_USER_CONTROL_CODE_NUMBER8},
  {"number9", CEC_USER_CONTROL_CODE_NUMBER9},
  {"number11", CEC_USER_CONTROL_CODE_NUMBER11},
  {"number12", CEC_USER_CONTROL_CODE_NUMBER12},
  {"dot", CEC_USER_CONTROL_CODE_DOT},
  {"enter", CEC_USER_CONTROL_CODE_ENTER},
  {"clear", CEC_USER_CONTROL_CODE_CLEAR},
  {"next_favorite", CEC_USER_CONTROL_CODE_NEXT_FAVORITE},
  {"channel_up", CEC_USER_CONTROL_CODE_CHANNEL_UP},
  {"channel_down", CEC_USER_CONTROL_CODE_CHANNEL_DOWN},
  {"previous_channel", CEC_USER_CONTROL_CODE_PREVIOUS_CHANNEL},
  {"sound_select", CEC_USER_CONTROL_CODE_SOUND_SELECT},
  {"input_select", CEC_USER_CONTROL_CODE_INPUT_SELECT},
  {"display_information", CEC_USER_CONTROL_CODE_DISPLAY_INFORMATION},
  {"help", CEC_USER_CONTROL_CODE_HELP},
  {"page_up", CEC_USER_CONTROL_CODE_PAGE_UP},
  {"page_down", CEC_USER_CONTROL_CODE_PAGE_DOWN},
  {"power", CEC_USER_CONTROL_CODE_POWER},
  {"volume_up", CEC_USER_CONTROL_CODE_VOLUME_UP},
  {"volume_down", CEC_USER_CONTROL_CODE_VOLUME_DOWN},
  {"mute", CEC_USER_CONTROL_CODE_MUTE},
  {"play", CEC_USER_CONTROL_CODE_PLAY},
  {"stop", CEC_USER_CONTROL_CODE_STOP},
  {"pause", CEC_USER_CONTROL_CODE_PAUSE},
  {"record", CEC_USER_CONTROL_CODE_RECORD},
  {"rewind", CEC_USER_CONTROL_CODE_REWIND},
  {"fast_forward", CEC_USER_CONTROL_CODE_FAST_FORWARD},
  {"eject", CEC_USER_CONTROL_CODE_EJECT},
  {"forward", CEC_USER_CONTROL_CODE_FORWARD},
  {"backward", CEC_USER_CONTROL_CODE_BACKWARD},
  {"stop_record", CEC_USER_CONTROL_CODE_STOP_RECORD},
  {"pause_record", CEC_USER_CONTROL_CODE_PAUSE_RECORD},
  {"angle", CEC_USER_CONTROL_CODE_ANGLE},
  {"sub_picture", CEC_USER_CONTROL_CODE_SUB_PICTURE},
  {"video_on_demand", CEC_USER_CONTROL_CODE_VIDEO_ON_DEMAND},
  {"epg", CEC_USER_CONTROL_CODE_ELECTRONIC_PROGRAM_GUIDE},
  {"timer_programming", CEC_USER_CONTROL_CODE_TIMER_PROGRAMMING},
  {"initial_configuration", CEC_USER_CONTROL_CODE_INITIAL_CONFIGURATION},
  {"play_function", CEC_USER_CONTROL_CODE_PLAY_FUNCTION},
  {"pause_play_function", CEC_USER_CONTROL_CODE_PAUSE_PLAY_FUNCTION},
  {"stop_function", CEC_USER_CONTROL_CODE_STOP_FUNCTION},
  {"mute_function", CEC_USER_CONTROL_CODE_MUTE_FUNCTION},
  {"power_toggle_function", CEC_USER_CONTROL_CODE_POWER_TOGGLE_FUNCTION},
  {"power_off_function", CEC_USER_CONTROL_CODE_POWER_OFF_FUNCTION},
  {"power_on_function", CEC_USER_CONTROL_CODE_POWER_ON_FUNCTION},
  {"f1_blue", CEC_USER_CONTROL_CODE_F1_BLUE},
  {"f2_red", CEC_USER_CONTROL_CODE_F2_RED},
  {"f3_green", CEC_USER_CONTROL_CODE_F3_GREEN},
  {"f4_yellow", CEC_USER_CONTROL_CODE_F4_YELLOW},
  {"f5", CEC_USER_CONTROL_CODE_F5},
  {"an_return", CEC_USER_CONTROL_CODE_AN_RETURN},
  {"an_channels_list", CEC_USER_CONTROL_CODE_AN_CHANNELS_LIST},
};

#define MAX_MAP 128
struct mapping {
  cec_user_control_code code;
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
    cec_user_control_code code = CEC_USER_CONTROL_CODE_UNKNOWN;
    size_t n = sizeof CEC_NAMES / sizeof CEC_NAMES[0];
    for (size_t i = 0; i < n; i++)
      if (strcmp(CEC_NAMES[i].name, name) == 0) {
        code = CEC_NAMES[i].code;
        break;
      }
    if (code == CEC_USER_CONTROL_CODE_UNKNOWN) {
      fprintf(stderr, "cec-kbd: unknown CEC button name '%s' in %s\n", name, path);
      continue;
    }
    if (g_map_len >= MAX_MAP)
      break;
    g_map[g_map_len].code = code;
    snprintf(g_map[g_map_len].spec, sizeof g_map[g_map_len].spec, "%s", spec);
    g_map_len++;
  }
  fclose(f);
  return g_map_len > 0 ? 0 : -1;
}

static const char *find_spec(cec_user_control_code code) {
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

static void on_key(void *cbparam, const cec_keypress *key) {
  (void)cbparam;
  if (!key)
    return;
  if (key->keycode == CEC_USER_CONTROL_CODE_UNKNOWN)
    return; /* button release marker */
  const char *spec = find_spec(key->keycode);
  if (!spec) {
    fprintf(stderr, "cec-kbd: unmapped CEC key 0x%02x (duration %u)\n",
            (unsigned)key->keycode, key->duration);
    return;
  }
  fprintf(stderr, "cec-kbd: CEC key 0x%02x -> %s\n", (unsigned)key->keycode, spec);
  tap_spec(spec);
}

static void on_log(void *cbparam, const cec_log_message *msg) {
  (void)cbparam;
  if (msg && msg->message)
    fprintf(stderr, "libcec: %s\n", msg->message);
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

  libcec_configuration config;
  memset(&config, 0, sizeof config);
  config.clientVersion = LIBCEC_VERSION_CURRENT;
  snprintf(config.strDeviceName, sizeof config.strDeviceName, "Jellyby");
  config.deviceTypes.types[0] = CEC_DEVICE_TYPE_RECORDING_DEVICE;
  for (int i = 1; i < 5; i++)
    config.deviceTypes.types[i] = CEC_DEVICE_TYPE_RESERVED;
  config.bActivateSource = 0;
  config.comboKey = CEC_USER_CONTROL_CODE_UNKNOWN;
  config.cecVersion = CEC_VERSION_1_4;

  libcec_connection_t conn = libcec_initialise(&config);
  if (!conn) {
    fprintf(stderr, "cec-kbd: libcec_initialise failed\n");
    return 1;
  }

  cec_adapter_descriptor adapters[8];
  int8_t n = libcec_detect_adapters(conn, adapters, 8, NULL, 0);
  /* Port choice: $CEC_KBD_PORT override, else the first detected adapter,
   * else the kernel CEC device (/dev/cec0: Pi 4 under vc4-kms, Rockchip
   * dw-hdmi), else libcec's legacy Raspberry Pi firmware adapter. */
  const char *port = getenv("CEC_KBD_PORT");
  if (!port || !*port) {
    if (n > 0)
      port = adapters[0].strComPath;
    else if (access("/dev/cec0", F_OK) == 0)
      port = "/dev/cec0";
    else
      port = "RPI";
  }
  fprintf(stderr, "cec-kbd: %d CEC adapter(s) found, opening '%s'\n", n, port);
  if (!libcec_open(conn, port, CEC_DEFAULT_CONNECT_TIMEOUT)) {
    fprintf(stderr, "cec-kbd: libcec_open('%s') failed\n", port);
    libcec_destroy(conn);
    return 1;
  }

  ICECCallbacks cb;
  memset(&cb, 0, sizeof cb);
  cb.keyPress = on_key;
  cb.logMessage = on_log;
#if defined(CEC_LIB_VERSION_MAJOR) && CEC_LIB_VERSION_MAJOR >= 5
  if (!libcec_set_callbacks(conn, &cb, NULL)) {
    fprintf(stderr, "cec-kbd: libcec_set_callbacks failed\n");
    libcec_close(conn);
    libcec_destroy(conn);
    return 1;
  }
#else
  libcec_enable_callbacks(conn, NULL, &cb);
#endif

  if (uinput_init() < 0) {
    fprintf(stderr, "cec-kbd: cannot create uinput device: %s\n", strerror(errno));
    libcec_close(conn);
    libcec_destroy(conn);
    return 1;
  }
  fprintf(stderr, "cec-kbd: listening for CEC key presses\n");

  signal(SIGTERM, on_signal);
  signal(SIGINT, on_signal);
  while (g_run)
    sleep(1);

  close(g_uinput);
  libcec_close(conn);
  libcec_destroy(conn);
  fprintf(stderr, "cec-kbd: stopped\n");
  return 0;
}
