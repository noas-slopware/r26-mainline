// SPDX-License-Identifier: GPL-2.0
/* riubc <byte>: set the upper byte of PM POR reg1 (0x1F000C04), keep bit0-7. Nothing else. */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
int main(int argc, char **argv)
{
	if (argc != 2)
		return fprintf(stderr, "usage: riubc <byte>\n"), 2;
	unsigned v = strtoul(argv[1], NULL, 16) & 0xff;
	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0)
		return perror("open"), 1;
	volatile uint8_t *p = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0x1f000000);
	if (p == MAP_FAILED)
		return perror("mmap"), 1;
	volatile uint16_t *r = (volatile uint16_t *)(p + 0xc04);
	uint16_t o = *r;
	*r = (o & 0x00ff) | v << 8;
	printf("1f000c04 %04x -> %04x\n", o, *r);
	return 0;
}
