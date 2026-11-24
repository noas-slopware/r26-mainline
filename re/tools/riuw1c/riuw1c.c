// SPDX-License-Identifier: GPL-2.0
/* riuw1c: clear the watchdog-reset flag (WDT reg2 bit0, write-1-to-clear). Nothing else. */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>
int main(void)
{
	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0)
		return perror("open"), 1;
	volatile uint8_t *p = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0x1f006000);
	if (p == MAP_FAILED)
		return perror("mmap"), 1;
	volatile uint16_t *r2 = (volatile uint16_t *)(p + 0x08);
	uint16_t v = *r2;
	*r2 = v | 1;
	printf("1f006008 %04x -> %04x\n", v, *r2);
	return 0;
}
