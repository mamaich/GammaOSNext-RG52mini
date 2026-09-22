/* Поднять hci0 и прочитать состояние контроллера.
   Статическая сборка -- работает на Android без Bionic и NDK. */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/ioctl.h>

#define AF_BT          31
#define BTPROTO_HCI     1
#define HCIDEVUP     0x400448c9
#define HCIDEVDOWN   0x400448ca
#define HCIGETDEVINFO 0x800448d3

struct di { unsigned short dev_id; char name[8]; unsigned char bdaddr[6];
            unsigned int flags; unsigned char type; unsigned char features[8];
            unsigned int pkt_type, link_policy, link_mode;
            unsigned short acl_mtu, acl_pkts, sco_mtu, sco_pkts;
            unsigned long stat[10]; };

int main(int argc, char **argv)
{
    int s = socket(AF_BT, SOCK_RAW, BTPROTO_HCI);
    if (s < 0) { printf("socket(AF_BLUETOOTH): %s\n", strerror(errno)); return 1; }

    if (argc > 1 && strcmp(argv[1], "down") == 0) {
        printf("HCIDEVDOWN -> %d\n", ioctl(s, HCIDEVDOWN, 0));
        return 0;
    }

    int r = ioctl(s, HCIDEVUP, 0);
    printf("HCIDEVUP -> %s\n", r < 0 ? strerror(errno) : "OK");

    struct di d;
    memset(&d, 0, sizeof d);
    d.dev_id = 0;
    if (ioctl(s, HCIGETDEVINFO, &d) == 0) {
        printf("name    : %s\n", d.name);
        printf("bdaddr  : %02X:%02X:%02X:%02X:%02X:%02X\n",
               d.bdaddr[5], d.bdaddr[4], d.bdaddr[3],
               d.bdaddr[2], d.bdaddr[1], d.bdaddr[0]);
        printf("flags   : 0x%08x\n", d.flags);
        printf("acl_mtu : %u   sco_mtu : %u\n", d.acl_mtu, d.sco_mtu);
    } else {
        printf("HCIGETDEVINFO: %s\n", strerror(errno));
    }
    close(s);
    return 0;
}
