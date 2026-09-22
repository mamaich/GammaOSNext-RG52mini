/* Управление произвольным hci-интерфейсом: hcidev <номер> [up|down|info]
 * Прошивка Realtek грузится драйвером не при подключении донгла,
 * а при первом HCIDEVUP, поэтому проверять надо именно так.
 * Собирается статически обычным aarch64-none-linux-gnu-gcc, NDK не нужен. */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define AF_BLUETOOTH_ 31
#define BTPROTO_HCI_   1
#define HCIDEVUP      0x400448c9
#define HCIDEVDOWN    0x400448ca
#define HCIGETDEVINFO 0x800448d3

struct hci_dev_stats { unsigned int err_rx, err_tx, cmd_tx, evt_rx,
                       acl_tx, acl_rx, sco_tx, sco_rx, byte_rx, byte_tx; };
struct hci_dev_info {
    unsigned short dev_id;
    char  name[8];
    unsigned char bdaddr[6];
    unsigned int  flags;
    unsigned char type;
    unsigned char features[8];
    unsigned int  pkt_type, link_policy, link_mode;
    unsigned short acl_mtu; unsigned short acl_pkts;
    unsigned short sco_mtu; unsigned short sco_pkts;
    struct hci_dev_stats stat;
};

int main(int argc, char **argv)
{
    int dev = (argc > 1) ? atoi(argv[1]) : 0;
    const char *cmd = (argc > 2) ? argv[2] : "up";
    int s = socket(AF_BLUETOOTH_, SOCK_RAW, BTPROTO_HCI_);
    if (s < 0) { printf("socket: %s\n", strerror(errno)); return 1; }

    if (strcmp(cmd, "up") == 0 || strcmp(cmd, "down") == 0) {
        int r = ioctl(s, strcmp(cmd, "down") ? HCIDEVUP : HCIDEVDOWN, dev);
        printf("%s hci%d -> %s\n", strcmp(cmd, "down") ? "HCIDEVUP" : "HCIDEVDOWN",
               dev, r < 0 ? strerror(errno) : "OK");
    }

    struct hci_dev_info d;
    memset(&d, 0, sizeof d);
    d.dev_id = dev;
    if (ioctl(s, HCIGETDEVINFO, &d) < 0) {
        printf("HCIGETDEVINFO: %s\n", strerror(errno));
        close(s); return 1;
    }
    printf("hci%d имя=%s тип=%u флаги=0x%x\n", d.dev_id, d.name, d.type, d.flags);
    printf("  BD-адрес: %02X:%02X:%02X:%02X:%02X:%02X\n",
           d.bdaddr[5], d.bdaddr[4], d.bdaddr[3], d.bdaddr[2], d.bdaddr[1], d.bdaddr[0]);
    printf("  ACL mtu=%u pkts=%u   SCO mtu=%u pkts=%u\n",
           d.acl_mtu, d.acl_pkts, d.sco_mtu, d.sco_pkts);
    printf("  команд отправлено=%u событий принято=%u ошибок rx=%u tx=%u\n",
           d.stat.cmd_tx, d.stat.evt_rx, d.stat.err_rx, d.stat.err_tx);
    close(s);
    return 0;
}
