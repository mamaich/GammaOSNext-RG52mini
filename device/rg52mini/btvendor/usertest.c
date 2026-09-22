/* Повторяет то, что делает Fluoride: забирает hci0 в HCI_CHANNEL_USER,
   шлёт HCI Reset и ждёт ответа. Показывает, работает ли этот путь вообще. */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/ioctl.h>

#define AF_BT         31
#define BTPROTO_HCI    1
#define CH_USER        1
#define HCIDEVDOWN  0x400448ca

struct shci { unsigned short f, dev, chan; };

static void dump(const char *tag, unsigned char *b, int n)
{
    printf("%s (%d байт):", tag, n);
    for (int i = 0; i < n && i < 32; i++) printf(" %02X", b[i]);
    printf("\n");
}

int main(void)
{
    int c = socket(AF_BT, SOCK_RAW, BTPROTO_HCI);
    if (c >= 0) { ioctl(c, HCIDEVDOWN, 0); close(c); }

    int s = socket(AF_BT, SOCK_RAW, BTPROTO_HCI);
    if (s < 0) { printf("socket: %s\n", strerror(errno)); return 1; }

    struct shci a = { AF_BT, 0, CH_USER };
    if (bind(s, (struct sockaddr *)&a, sizeof a) < 0) {
        printf("bind(USER): %s\n", strerror(errno)); return 1;
    }
    printf("bind(HCI_CHANNEL_USER) OK, fd=%d\n", s);

    /* HCI Reset: H4-тип 01, опкод 0x0C03, длина 0 */
    unsigned char reset[] = { 0x01, 0x03, 0x0C, 0x00 };
    int w = write(s, reset, sizeof reset);
    dump("-> отправлено", reset, sizeof reset);
    if (w != (int)sizeof reset) printf("   write вернул %d: %s\n", w, strerror(errno));

    struct pollfd p = { s, POLLIN, 0 };
    for (int i = 0; i < 3; i++) {
        int r = poll(&p, 1, 1500);
        if (r == 0) { printf("<- таймаут %d/3\n", i + 1); continue; }
        if (r < 0) { printf("poll: %s\n", strerror(errno)); break; }
        unsigned char buf[260];
        int n = read(s, buf, sizeof buf);
        if (n <= 0) { printf("read: %s\n", strerror(errno)); break; }
        dump("<- ПОЛУЧЕНО", buf, n);
        break;
    }
    close(s);
    return 0;
}
