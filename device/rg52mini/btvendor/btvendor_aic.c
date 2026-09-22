/*
 * libbt-vendor для AIC8800 на RG52 Mini.
 *
 * Ядро (aic8800_fdrv с CONFIG_SDIO_BT=y, ветка BlueZ) даёт обычный hci0
 * и само заливает прошивку, поэтому здесь нет ни firmware, ни питания,
 * ни UART -- нужно лишь отдать Fluoride поток H4.
 *
 * Тонкость: HAL читает дескриптор ПОТОКОВО (байт типа, затем заголовок,
 * затем тело), а HCI-сокет пакетный -- чтение одного байта отбрасывает
 * остаток датаграммы. Поэтому наружу отдаётся socketpair (SOCK_STREAM),
 * а поток-ретранслятор переносит данные между ним и HCI-сокетом,
 * собирая на передаче целые H4-пакеты по их заголовкам.
 */

#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <android/log.h>

#define LOG_TAG "bt-vendor-aic"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

#define AF_BLUETOOTH_     31
#define BTPROTO_HCI_       1
#define HCI_CHANNEL_USER_  1
#define HCIDEVDOWN_  0x400448ca
#define HCI_DEV_ID         0

struct sockaddr_hci_ { unsigned short hci_family, hci_dev, hci_channel; };

enum {
    OP_POWER_CTRL = 0, OP_FW_CFG, OP_SCO_CFG, OP_USERIAL_OPEN,
    OP_USERIAL_CLOSE, OP_GET_LPM_IDLE_TIMEOUT, OP_LPM_SET_MODE,
    OP_LPM_WAKE_SET_STATE, OP_SET_AUDIO_STATE, OP_EPILOG,
    OP_A2DP_OFFLOAD_START, OP_A2DP_OFFLOAD_STOP
};
#define RESULT_SUCCESS 0
#define CH_MAX         4

typedef void (*cfg_result_cb)(int result);
typedef void* (*malloc_cb)(int size);
typedef void (*mdealloc_cb)(void *p);
typedef uint8_t (*cmd_xmit_cb)(uint16_t opcode, void *p_buf, void *cback);

typedef struct {
    size_t size;
    cfg_result_cb fwcfg_cb, scocfg_cb, lpm_cb, audio_state_cb;
    malloc_cb alloc; mdealloc_cb dealloc; cmd_xmit_cb xmit_cb;
    cfg_result_cb epilog_cb, a2dp_offload_cb;
} vnd_callbacks_t;

typedef struct {
    size_t size;
    int  (*init)(const vnd_callbacks_t *cb, unsigned char *local_bdaddr);
    int  (*op)(int opcode, void *param);
    void (*cleanup)(void);
} vnd_interface_t;

static const vnd_callbacks_t *g_cb;
static int g_hci = -1;      /* HCI-сокет к ядру      */
static int g_our = -1;      /* наш конец socketpair  */
static int g_hal = -1;      /* конец, отданный HAL   */
static pthread_t g_relay;
static volatile int g_run;

/* Полная длина H4-пакета по его заголовку; 0 -- данных пока мало. */
static int h4_len(const unsigned char *b, int n)
{
    if (n < 1) return 0;
    switch (b[0]) {
    case 0x01: return (n < 4) ? 0 : 4 + b[3];                    /* command */
    case 0x02: return (n < 5) ? 0 : 5 + (b[3] | (b[4] << 8));    /* ACL     */
    case 0x03: return (n < 4) ? 0 : 4 + b[3];                    /* SCO     */
    case 0x04: return (n < 3) ? 0 : 3 + b[2];                    /* event   */
    default:   return -1;                                        /* мусор   */
    }
}

static void *relay(void *unused)
{
    unsigned char tx[4096];
    int txn = 0;
    (void)unused;

    while (g_run) {
        struct pollfd p[2] = { { g_hci, POLLIN, 0 }, { g_our, POLLIN, 0 } };
        if (poll(p, 2, 500) <= 0) continue;

        /* контроллер -> HAL: пакет читаем целиком, отдаём потоком */
        if (p[0].revents & POLLIN) {
            unsigned char buf[2048];
            int n = read(g_hci, buf, sizeof buf);
            if (n > 0) {
                if (write(g_our, buf, n) != n) LOGE("write в HAL не полный");
            } else if (n < 0 && errno != EAGAIN && errno != EINTR) {
                LOGE("read hci: %s", strerror(errno)); break;
            }
        }

        /* HAL -> контроллер: копим поток и шлём целыми пакетами */
        if (p[1].revents & POLLIN) {
            int n = read(g_our, tx + txn, sizeof tx - txn);
            if (n > 0) {
                txn += n;
                for (;;) {
                    int len = h4_len(tx, txn);
                    if (len < 0) { LOGE("неизвестный тип 0x%02X, сброс", tx[0]); txn = 0; break; }
                    if (len == 0 || len > txn) break;      /* ждём остаток */
                    if (write(g_hci, tx, len) != len)
                        LOGE("write в hci: %s", strerror(errno));
                    memmove(tx, tx + len, txn - len);
                    txn -= len;
                }
            } else if (n == 0) { break; }
            else if (errno != EAGAIN && errno != EINTR) {
                LOGE("read HAL: %s", strerror(errno)); break;
            }
        }
        if ((p[0].revents | p[1].revents) & (POLLERR | POLLHUP)) break;
    }
    LOGI("ретранслятор остановлен");
    return NULL;
}

static int userial_open(int (*fds)[CH_MAX])
{
    struct sockaddr_hci_ a;
    int sv[2], c;

    c = socket(AF_BLUETOOTH_, SOCK_RAW, BTPROTO_HCI_);
    if (c >= 0) { ioctl(c, HCIDEVDOWN_, HCI_DEV_ID); close(c); }

    g_hci = socket(AF_BLUETOOTH_, SOCK_RAW, BTPROTO_HCI_);
    if (g_hci < 0) { LOGE("socket: %s", strerror(errno)); return 0; }

    memset(&a, 0, sizeof a);
    a.hci_family = AF_BLUETOOTH_; a.hci_dev = HCI_DEV_ID;
    a.hci_channel = HCI_CHANNEL_USER_;
    if (bind(g_hci, (struct sockaddr *)&a, sizeof a) < 0) {
        LOGE("bind(HCI_CHANNEL_USER): %s", strerror(errno));
        close(g_hci); g_hci = -1; return 0;
    }

    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) {
        LOGE("socketpair: %s", strerror(errno));
        close(g_hci); g_hci = -1; return 0;
    }
    g_our = sv[0]; g_hal = sv[1];

    g_run = 1;
    if (pthread_create(&g_relay, NULL, relay, NULL) != 0) {
        LOGE("pthread_create: %s", strerror(errno));
        close(g_hci); close(g_our); close(g_hal);
        g_hci = g_our = g_hal = -1; return 0;
    }

    LOGI("hci%d захвачен, ретранслятор поднят, fd для HAL=%d", HCI_DEV_ID, g_hal);
    (*fds)[0] = g_hal;
    return 1;
}

static void userial_close(void)
{
    if (!g_run && g_hci < 0) return;
    g_run = 0;
    if (g_our >= 0) { shutdown(g_our, SHUT_RDWR); }
    pthread_join(g_relay, NULL);
    if (g_our >= 0) { close(g_our); g_our = -1; }
    if (g_hci >= 0) { close(g_hci); g_hci = -1; }
    g_hal = -1;   /* этот конец закрывает HAL */
}

static int vnd_init(const vnd_callbacks_t *cb, unsigned char *bdaddr)
{
    (void)bdaddr; g_cb = cb;
    LOGI("init");
    return 0;
}

static int vnd_op(int opcode, void *param)
{
    LOGI("op(%d)", opcode);
    switch (opcode) {
    case OP_POWER_CTRL:   return 0;
    case OP_USERIAL_OPEN: return userial_open((int (*)[CH_MAX])param);
    case OP_USERIAL_CLOSE: userial_close(); return 0;
    case OP_FW_CFG:  if (g_cb && g_cb->fwcfg_cb)  g_cb->fwcfg_cb(RESULT_SUCCESS);  return 0;
    case OP_SCO_CFG: if (g_cb && g_cb->scocfg_cb) g_cb->scocfg_cb(RESULT_SUCCESS); return 0;
    case OP_LPM_SET_MODE: if (g_cb && g_cb->lpm_cb) g_cb->lpm_cb(RESULT_SUCCESS);  return 0;
    case OP_SET_AUDIO_STATE:
        if (g_cb && g_cb->audio_state_cb) g_cb->audio_state_cb(RESULT_SUCCESS); return 0;
    case OP_EPILOG:  if (g_cb && g_cb->epilog_cb) g_cb->epilog_cb(RESULT_SUCCESS); return 0;
    case OP_GET_LPM_IDLE_TIMEOUT: if (param) *((uint32_t *)param) = 0; return 0;
    default: return 0;
    }
}

static void vnd_cleanup(void)
{
    LOGI("cleanup");
    userial_close();
    g_cb = NULL;
}

__attribute__((visibility("default")))
const vnd_interface_t BLUETOOTH_VENDOR_LIB_INTERFACE = {
    sizeof(vnd_interface_t), vnd_init, vnd_op, vnd_cleanup
};
