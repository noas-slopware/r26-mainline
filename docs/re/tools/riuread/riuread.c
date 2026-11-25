// riuread: read-only dump of 16-bit RIU registers through /dev/mem.
// usage: riuread <phys-hex> <count>   (reads <count> regs at 4-byte stride)
// Built static with kernel nolibc. Never writes anything.
#include "nolibc.h"

static unsigned long parse_hex(const char *s)
{
	unsigned long v = 0;
	if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
		s += 2;
	for (; *s; s++) {
		int c = *s, d;
		if (c >= '0' && c <= '9') d = c - '0';
		else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
		else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
		else break;
		v = v * 16 + d;
	}
	return v;
}

static void puthex(unsigned long v, int digits)
{
	char b[16];
	for (int i = digits - 1; i >= 0; i--, v >>= 4)
		b[i] = "0123456789abcdef"[v & 15];
	write(1, b, digits);
}

int main(int argc, char **argv)
{
	if (argc != 3) {
		write(2, "usage: riuread <phys> <count>\n", 30);
		return 2;
	}
	unsigned long phys = parse_hex(argv[1]);
	int count = atoi(argv[2]);
	unsigned long page = phys & ~0xfffUL, off = phys - page;
	unsigned long len = (off + count * 4 + 0xfff) & ~0xfffUL;
	int fd = open("/dev/mem", O_RDONLY | O_SYNC);
	if (fd < 0) {
		write(2, "open /dev/mem failed\n", 21);
		return 1;
	}
	volatile unsigned char *m = mmap(NULL, len, PROT_READ, MAP_SHARED, fd, page);
	if (m == MAP_FAILED) {
		write(2, "mmap failed\n", 12);
		return 1;
	}
	for (int i = 0; i < count; i++) {
		unsigned short v = *(volatile unsigned short *)(m + off + i * 4);
		puthex(phys + i * 4, 8);
		write(1, " ", 1);
		puthex(v, 4);
		write(1, "\n", 1);
	}
	return 0;
}
