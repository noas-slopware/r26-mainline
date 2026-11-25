// SPDX-License-Identifier: GPL-2.0
/* r26peek <phys>...: print the 16-bit RIU register at each address. Read only. */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	int fd = open("/dev/mem", O_RDONLY | O_SYNC);

	if (fd < 0) {
		perror("/dev/mem");
		return 1;
	}
	for (int i = 1; i < argc; i++) {
		unsigned long pa = strtoul(argv[i], NULL, 0);
		volatile uint8_t *p = mmap(NULL, 4096, PROT_READ, MAP_SHARED, fd, pa & ~0xfffUL);

		if (p == MAP_FAILED) {
			perror("mmap");
			return 1;
		}
		printf("%08lx %04x\n", pa, *(volatile uint16_t *)(p + (pa & 0xffe)));
		fflush(stdout);
		munmap((void *)p, 4096);
	}
	return 0;
}
