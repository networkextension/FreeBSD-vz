# FreeBSD-vz

Run **FreeBSD/arm64 headless in a virtual machine using Apple's
Virtualization.framework**, with the guest console on your terminal and SSH
access — on Apple silicon Macs.

`FreeBSDVZ` is a small Swift command-line launcher. `main.swift` boots a FreeBSD
raw disk image via EFI, wires the guest's virtio console to this process's
stdin/stdout, and NATs the guest onto the network. `mkimg.sh` builds a matching
bootable image.

> **Status:** works with a FreeBSD kernel that carries the Apple-VZ fixes listed
> below. Stock FreeBSD does **not** yet boot under Virtualization.framework;
> getting there required a chain of kernel and configuration fixes, two of which
> are proposed upstream.

## Why this is needed (the Apple VZ boot-blocker chain)

FreeBSD/arm64 does not boot on Virtualization.framework out of the box. Each fix
below unblocks the next stage; the launcher + `mkimg.sh` here encode all of them.

1. **GIC version = 0.** VZ's ACPI MADT reports the GIC distributor version as
   `NONE`; FreeBSD's `gic_v3_acpi` only accepts 3/4 and bails, so the interrupt
   controller never attaches and the kernel panics with *"No usable event timer
   found"*. Fix: detect the version from `GICD_PIDR2` (as Linux does).
2. **No readable console.** VZ has no UART, and its virtio-gpu is a Blt-only GOP
   with no linear framebuffer, so `vt_efifb` never renders — kernel output is
   invisible. Fix: a low-level (`consdev`) console in `virtio_console(4)`, so the
   virtio console carries kernel `printf`/`panic` and a getty (like Linux hvc0).
3. **virtio-gpu hangs at attach.** FreeBSD's `vtgpu` driver spins forever
   attaching to VZ's GPU. Workaround: a kernel config without `virtio_gpu`.
4. **USB/XHCI is fatal.** If the VM has any USB device, VZ presents an XHCI
   controller and FreeBSD's USB stack dies in `bus_dmamem_alloc`. Workaround:
   run headless — this launcher adds **no** USB devices.
5. **`boot_verbose` spins.** Verbose early enumeration hangs forever on VZ.
   Workaround: never set `boot_verbose` in `loader.conf`.
6. **vtnet feature negotiation.** VZ's virtio-net rejects FreeBSD's full offload
   feature set (attach error 45). Workaround: trim it in `loader.conf` with
   `hw.vtnet.{csum,tso,lro,mq}_disable="1"`.

Fixes 1 and 2 are kernel patches; a branch carrying both (plus a `VZ` kernel
config for 3) lives at:
<https://github.com/networkextension/freebsd-src/tree/apple-vz-virtio-console>

## Build the launcher

Requires macOS 13+ and the Xcode command line tools.

```sh
sh build.sh          # swiftc + ad-hoc codesign with the virtualization entitlement
```

The `com.apple.security.virtualization` entitlement is mandatory (the VM refuses
to start otherwise); ad-hoc signing (`codesign -s -`) is enough.

## Build a bootable image

On a FreeBSD host, check out a source tree with the VZ patches (branch above),
add the `VZ` kernel config (`sys/arm64/conf/VZ` = `include GENERIC` +
`nodevice virtio_gpu`), then:

```sh
make -j"$(sysctl -n hw.ncpu)" buildworld  TARGET=arm64 TARGET_ARCH=aarch64
make -j"$(sysctl -n hw.ncpu)" buildkernel TARGET=arm64 TARGET_ARCH=aarch64 KERNCONF=VZ
SSHKEY="$(cat ~/.ssh/id_ed25519.pub)" doas sh mkimg.sh      # -> /tmp/freebsd-vz.img
```

Copy the image to your Mac (it is sparse; stream it compressed):

```sh
ssh builder 'gzip -1 -c /tmp/freebsd-vz.img' | gunzip | dd of=freebsd-vz.img bs=1m conv=sparse
```

## Run

```sh
./FreeBSDVZ freebsd-vz.img
```

You get the FreeBSD console in your terminal (login `root`, empty password on the
image `mkimg.sh` builds). Once it is up and has a DHCP lease, `ssh root@<ip>`
with the key you baked in. An optional second argument attaches a read-only
image (e.g. a cloud-init NoCloud seed) as a **virtio-blk** device — not USB.

Per-image state (`<image>.efivars`, `<image>.machineid`) is created next to the
disk image; delete those files to reset the VM's NVRAM and identity.

## Credits

Adapted from Apple's "Running Linux in a Virtual Machine" sample. The GUI
counterpart by a FreeBSD developer:
<https://github.com/jlduran/RunningGUIFreeBSDInAVirtualMachineOnAMac>.
