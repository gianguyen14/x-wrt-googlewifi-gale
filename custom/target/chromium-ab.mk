# =============================================================================
# Google WiFi Gale - A/B Partition Image Generation
# =============================================================================
# This Makefile fragment extends the standard chromium image generation
# to create A/B factory images with dual rootfs and data partition.
# =============================================================================
# Include this from the main chromium.mk or use alongside it.

# Partition sizes (in MB)
AB_KERN_SIZE := 16
AB_ROOT_SIZE := 512
AB_DATA_SIZE := 512

# ChromeOS GPT type GUIDs
CHROMEOS_KERNEL_GUID := FE3A2A5D-4F32-41A7-B725-ACCC3285A309
CHROMEOS_ROOTFS_GUID := 3CB8E202-3B7E-47DD-8A3C-7FF2A13CFCEC
LINUX_FS_GUID := 0FC63DAF-8483-4772-8E79-3D69D8477DE4

define Build/ab-gale-image
	$(eval AB_IMG := $@-ab-factory.bin)
	$(eval TOTAL_MB := $(shell echo $$((2 + $(AB_KERN_SIZE) + $(AB_ROOT_SIZE) + $(AB_KERN_SIZE) + $(AB_ROOT_SIZE) + $(AB_DATA_SIZE) + 2))))

	# Create empty image
	dd if=/dev/zero of=$(AB_IMG) bs=1M count=$(TOTAL_MB) conv=fsync

	# Create GPT partition table
	sgdisk --clear $(AB_IMG)

	# KERN-A (ChromeOS kernel type)
	sgdisk --new=1:2048:+$(AB_KERN_SIZE)M \
	       --change-name=1:KERN-A \
	       --typecode=1:$(CHROMEOS_KERNEL_GUID) \
	       $(AB_IMG)

	# ROOT-A (ChromeOS rootfs type)
	sgdisk --new=2:0:+$(AB_ROOT_SIZE)M \
	       --change-name=2:ROOT-A \
	       --typecode=2:$(CHROMEOS_ROOTFS_GUID) \
	       $(AB_IMG)

	# KERN-B (ChromeOS kernel type)
	sgdisk --new=3:0:+$(AB_KERN_SIZE)M \
	       --change-name=3:KERN-B \
	       --typecode=3:$(CHROMEOS_KERNEL_GUID) \
	       $(AB_IMG)

	# ROOT-B (ChromeOS rootfs type)
	sgdisk --new=4:0:+$(AB_ROOT_SIZE)M \
	       --change-name=4:ROOT-B \
	       --typecode=4:$(CHROMEOS_ROOTFS_GUID) \
	       $(AB_IMG)

	# DATA (standard Linux filesystem)
	sgdisk --new=5:0:+$(AB_DATA_SIZE)M \
	       --change-name=5:DATA \
	       --typecode=5:$(LINUX_FS_GUID) \
	       $(AB_IMG)

	# Set ChromeOS boot attributes:
	# Slot A: priority=2, tries=0, successful=1 (active, known good)
	# Slot B: priority=1, tries=0, successful=0 (standby)
	sgdisk --attributes=1:=:0x0100000000000002 $(AB_IMG)
	sgdisk --attributes=3:=:0x0000000000000001 $(AB_IMG)

	# Write kernel image to both KERN-A and KERN-B
	$(if $(wildcard $(KDIR)/fit-*.itb), \
		$(eval KERN_A_START := $(shell sgdisk --info=1 $(AB_IMG) 2>/dev/null | grep "First sector" | awk '{print $$3}')) \
		$(eval KERN_B_START := $(shell sgdisk --info=3 $(AB_IMG) 2>/dev/null | grep "First sector" | awk '{print $$3}')) \
		dd if=$(KDIR)/fit-*.itb of=$(AB_IMG) bs=512 seek=$(KERN_A_START) conv=notrunc 2>/dev/null; \
		dd if=$(KDIR)/fit-*.itb of=$(AB_IMG) bs=512 seek=$(KERN_B_START) conv=notrunc 2>/dev/null; \
	)

	# Write squashfs rootfs to both ROOT-A and ROOT-B
	$(if $(wildcard $(KDIR)/root.squashfs), \
		$(eval ROOT_A_START := $(shell sgdisk --info=2 $(AB_IMG) 2>/dev/null | grep "First sector" | awk '{print $$3}')) \
		$(eval ROOT_B_START := $(shell sgdisk --info=4 $(AB_IMG) 2>/dev/null | grep "First sector" | awk '{print $$3}')) \
		dd if=$(KDIR)/root.squashfs of=$(AB_IMG) bs=512 seek=$(ROOT_A_START) conv=notrunc 2>/dev/null; \
		dd if=$(KDIR)/root.squashfs of=$(AB_IMG) bs=512 seek=$(ROOT_B_START) conv=notrunc 2>/dev/null; \
	)

	# Verify final GPT
	sgdisk --verify $(AB_IMG) || true
	sgdisk --print $(AB_IMG)

	@echo "A/B factory image created: $(AB_IMG)"
	@echo "  KERN-A:  $(AB_KERN_SIZE) MB"
	@echo "  ROOT-A:  $(AB_ROOT_SIZE) MB"
	@echo "  KERN-B:  $(AB_KERN_SIZE) MB"
	@echo "  ROOT-B:  $(AB_ROOT_SIZE) MB"
	@echo "  DATA:    $(AB_DATA_SIZE) MB"
endef
