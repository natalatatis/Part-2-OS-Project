CC      = arm-none-eabi-gcc
LD      = arm-none-eabi-ld
OBJCOPY = arm-none-eabi-objcopy

OS    = OS
LIB   = Library
INC   = include
P1    = P1
P2    = P2
BUILD = build

CFLAGS = -ffreestanding -nostdlib -nostartfiles -g -I$(INC) -I$(LIB) -I$(OS)

.PHONY: qemu beagle clean \
        _build_os_beagle _build_os_qemu \
        _build_p1_beagle _build_p2_beagle \
        _build_p1_qemu   _build_p2_qemu

# ============================================================
# BeagleBone — separate binaries
# ============================================================

beagle: clean _build_p1_beagle _build_p2_beagle _build_os_beagle
	@echo "================================"
	@echo " Deploying to BeagleBone Black"
	@echo "================================"
	./deploy_beagle.sh

_build_os_beagle: $(BUILD)
	$(CC) -c $(OS)/root_beagle.s $(CFLAGS) -DTARGET_BEAGLE -mcpu=cortex-a8 -marm -o $(BUILD)/start.o
	$(CC) -c $(OS)/os.c          $(CFLAGS) -DTARGET_BEAGLE -mcpu=cortex-a8 -marm -o $(BUILD)/os.o
	$(LD) -T $(OS)/linker_beagle.ld $(BUILD)/start.o $(BUILD)/os.o -o $(BUILD)/kernel.elf
	$(OBJCOPY) -O binary $(BUILD)/kernel.elf $(BUILD)/kernel.bin

_build_p1_beagle: $(BUILD)
	$(CC) -c $(P1)/root.s    $(CFLAGS) -DTARGET_BEAGLE -mcpu=cortex-a8 -marm -o $(BUILD)/p1_root.o
	$(CC) -c $(P1)/main.c    $(CFLAGS) -DTARGET_BEAGLE -mcpu=cortex-a8 -marm -o $(BUILD)/p1.o
	$(CC) -c $(LIB)/stdio.c  $(CFLAGS) -DTARGET_BEAGLE -mcpu=cortex-a8 -marm -o $(BUILD)/p1_stdio.o
	$(CC) -c $(LIB)/string.c $(CFLAGS) -DTARGET_BEAGLE -mcpu=cortex-a8 -marm -o $(BUILD)/p1_string.o
	$(CC) -c $(LIB)/io.c     $(CFLAGS) -DTARGET_BEAGLE -mcpu=cortex-a8 -marm -o $(BUILD)/p1_io.o

	$(LD) -T $(P1)/p1.ld \
		$(BUILD)/p1_root.o \
		$(BUILD)/p1.o \
		$(BUILD)/p1_stdio.o \
		$(BUILD)/p1_string.o \
		$(BUILD)/p1_io.o \
		-o $(BUILD)/p1.elf

	$(OBJCOPY) -O binary $(BUILD)/p1.elf $(BUILD)/p1.bin


_build_p2_beagle: $(BUILD)
	$(CC) -c $(P2)/root.s    $(CFLAGS) -DTARGET_BEAGLE -mcpu=cortex-a8 -marm -o $(BUILD)/p2_root.o
	$(CC) -c $(P2)/main.c    $(CFLAGS) -DTARGET_BEAGLE -mcpu=cortex-a8 -marm -o $(BUILD)/p2.o
	$(CC) -c $(LIB)/stdio.c  $(CFLAGS) -DTARGET_BEAGLE -mcpu=cortex-a8 -marm -o $(BUILD)/p2_stdio.o
	$(CC) -c $(LIB)/string.c $(CFLAGS) -DTARGET_BEAGLE -mcpu=cortex-a8 -marm -o $(BUILD)/p2_string.o
	$(CC) -c $(LIB)/io.c     $(CFLAGS) -DTARGET_BEAGLE -mcpu=cortex-a8 -marm -o $(BUILD)/p2_io.o

	$(LD) -T $(P2)/p2.ld \
		$(BUILD)/p2_root.o \
		$(BUILD)/p2.o \
		$(BUILD)/p2_stdio.o \
		$(BUILD)/p2_string.o \
		$(BUILD)/p2_io.o \
		-o $(BUILD)/p2.elf

	$(OBJCOPY) -O binary $(BUILD)/p2.elf $(BUILD)/p2.bin

# ============================================================
# QEMU — separate binaries (Approach 2: Generic Loader)
# ============================================================

# Launch QEMU and tell it to load the binary files into specific addresses
qemu: clean _build_p1_qemu _build_p2_qemu _build_os_qemu
	@echo "================================"
	@echo " Launching QEMU"
	@echo "================================"
	qemu-system-arm -M versatilepb -cpu arm926 -nographic \
		-kernel $(BUILD)/kernel.elf \
		-device loader,file=$(BUILD)/p1.bin,addr=0x00100000 \
		-device loader,file=$(BUILD)/p2.bin,addr=0x00200000

_build_p1_qemu: $(BUILD)
	$(CC) -c $(P1)/main.c    $(CFLAGS) -DTARGET_QEMU -mcpu=arm926ej-s -marm -o $(BUILD)/p1.o
	$(CC) -c $(LIB)/stdio.c  $(CFLAGS) -DTARGET_QEMU -mcpu=arm926ej-s -marm -o $(BUILD)/p1_stdio.o
	$(CC) -c $(LIB)/string.c $(CFLAGS) -DTARGET_QEMU -mcpu=arm926ej-s -marm -o $(BUILD)/p1_string.o
	$(CC) -c $(LIB)/io.c     $(CFLAGS) -DTARGET_QEMU -mcpu=arm926ej-s -marm -o $(BUILD)/p1_io.o
	$(LD) -T $(P1)/linker_p1_qemu.ld $(BUILD)/p1.o $(BUILD)/p1_stdio.o $(BUILD)/p1_string.o $(BUILD)/p1_io.o -o $(BUILD)/p1.elf
	$(OBJCOPY) -O binary $(BUILD)/p1.elf $(BUILD)/p1.bin

_build_p2_qemu: $(BUILD)
	$(CC) -c $(P2)/main.c    $(CFLAGS) -DTARGET_QEMU -mcpu=arm926ej-s -marm -o $(BUILD)/p2.o
	$(CC) -c $(LIB)/stdio.c  $(CFLAGS) -DTARGET_QEMU -mcpu=arm926ej-s -marm -o $(BUILD)/p2_stdio.o
	$(CC) -c $(LIB)/string.c $(CFLAGS) -DTARGET_QEMU -mcpu=arm926ej-s -marm -o $(BUILD)/p2_string.o
	$(CC) -c $(LIB)/io.c     $(CFLAGS) -DTARGET_QEMU -mcpu=arm926ej-s -marm -o $(BUILD)/p2_io.o
	$(LD) -T $(P2)/linker_p2_qemu.ld $(BUILD)/p2.o $(BUILD)/p2_stdio.o $(BUILD)/p2_string.o $(BUILD)/p2_io.o -o $(BUILD)/p2.elf
	$(OBJCOPY) -O binary $(BUILD)/p2.elf $(BUILD)/p2.bin

_build_os_qemu: $(BUILD)
	$(CC) -c $(OS)/root_qemu.s $(CFLAGS) -DTARGET_QEMU -mcpu=arm926ej-s -marm -o $(BUILD)/start.o
	$(CC) -c $(OS)/os.c        $(CFLAGS) -DTARGET_QEMU -mcpu=arm926ej-s -marm -o $(BUILD)/os.o
	$(LD) -T $(OS)/linker_qemu.ld $(BUILD)/start.o $(BUILD)/os.o -o $(BUILD)/kernel.elf
	$(OBJCOPY) -O binary $(BUILD)/kernel.elf $(BUILD)/kernel.bin

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)