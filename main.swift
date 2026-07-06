/*
 FreeBSD-vz: run FreeBSD headless in a virtual machine using Apple's
 Virtualization.framework, with the guest console on this terminal.

 Usage:
     FreeBSDVZ <disk-image> [seed-image]

 <disk-image>  A FreeBSD arm64 (aarch64) raw disk image, attached read-write as
               a virtio-blk device.  Build one with the accompanying mkimg.sh,
               or grow an official VM-IMAGE.
 [seed-image]  Optional read-only image (e.g. a cloud-init NoCloud seed),
               attached as a *second virtio-blk* device.  It is deliberately
               NOT a USB device: VZ's XHCI controller trips a fatal
               bus_dmamem_alloc alignment fault in FreeBSD's USB stack.

 The guest console is a virtio console wired to this process's stdin/stdout
 (stdin in raw mode, restored on exit).  A FreeBSD kernel built with the
 virtio_console low-level console patch drives its system console over this
 channel, so you get kernel messages and a getty login right here.

 Notes for the guest image (see README):
   - Kernel needs the GICD_PIDR2 GIC-version fix and the vtcon console patch.
   - Kernel must NOT include virtio_gpu (its driver hangs at attach on VZ).
   - loader.conf must NOT set boot_verbose (verbose early enumeration spins),
     and should trim vtnet offloads (hw.vtnet.{csum,tso,lro,mq}_disable=1) or
     vtnet0 fails feature negotiation.
*/

import Foundation
import Virtualization

// MARK: Arguments

guard CommandLine.argc == 2 || CommandLine.argc == 3 else {
    FileHandle.standardError.write(Data("Usage: \(CommandLine.arguments[0]) <disk-image> [seed-image]\n".utf8))
    exit(EX_USAGE)
}

let diskURL = URL(fileURLWithPath: CommandLine.arguments[1])
let seedURL: URL? = CommandLine.argc == 3 ? URL(fileURLWithPath: CommandLine.arguments[2]) : nil

guard FileManager.default.fileExists(atPath: diskURL.path) else {
    FileHandle.standardError.write(Data("Disk image not found: \(diskURL.path)\n".utf8))
    exit(EXIT_FAILURE)
}

// The EFI variable store and machine identifier persist next to the disk image
// so the guest keeps a stable identity (NVRAM boot entries, MAC seed).
let supportDir = diskURL.deletingLastPathComponent()
let efiVarsURL = supportDir.appendingPathComponent(diskURL.lastPathComponent + ".efivars")
let machineIDURL = supportDir.appendingPathComponent(diskURL.lastPathComponent + ".machineid")

// MARK: Configuration

let cfg = VZVirtualMachineConfiguration()
cfg.cpuCount = max(2, min(4, ProcessInfo.processInfo.processorCount))
cfg.memorySize = 4 * 1024 * 1024 * 1024 // 4 GiB
cfg.memorySize = max(cfg.memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize)

do {
    cfg.platform = try makePlatform()
    cfg.bootLoader = try makeBootLoader()
    cfg.storageDevices = try makeStorage()
} catch {
    FileHandle.standardError.write(Data("Configuration failed: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}

cfg.serialPorts = [makeConsole()]
cfg.networkDevices = [makeNetwork()]
cfg.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

// A graphics device gives EFI a framebuffer for the loader.  The guest kernel
// omits virtio_gpu, so it simply ignores the device; no USB devices are added
// (VZ's XHCI is fatal for FreeBSD's USB stack), which keeps this headless.
let gfx = VZVirtioGraphicsDeviceConfiguration()
gfx.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1024, heightInPixels: 768)]
cfg.graphicsDevices = [gfx]

do {
    try cfg.validate()
} catch {
    FileHandle.standardError.write(Data("Invalid configuration: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}

// MARK: Run

let vm = VZVirtualMachine(configuration: cfg)
let delegate = Delegate()
vm.delegate = delegate
vm.start { result in
    if case let .failure(error) = result {
        FileHandle.standardError.write(Data("Failed to start: \(error)\n".utf8))
        exit(EXIT_FAILURE)
    }
}
RunLoop.main.run(until: .distantFuture)

// MARK: - Delegate

final class Delegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ vm: VZVirtualMachine) {
        FileHandle.standardError.write(Data("\nGuest stopped. Exiting.\n".utf8))
        exit(EXIT_SUCCESS)
    }
    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("\nGuest stopped with error: \(error)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

// MARK: - Builders

func makePlatform() throws -> VZPlatformConfiguration {
    let platform = VZGenericPlatformConfiguration()
    if let data = try? Data(contentsOf: machineIDURL) {
        guard let id = VZGenericMachineIdentifier(dataRepresentation: data) else {
            throw NSError(domain: "FreeBSDVZ", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "corrupt machine id at \(machineIDURL.path); delete it"])
        }
        platform.machineIdentifier = id
    } else {
        try platform.machineIdentifier.dataRepresentation.write(to: machineIDURL)
    }
    return platform
}

func makeBootLoader() throws -> VZBootLoader {
    let loader = VZEFIBootLoader()
    loader.variableStore = FileManager.default.fileExists(atPath: efiVarsURL.path)
        ? VZEFIVariableStore(url: efiVarsURL)
        : try VZEFIVariableStore(creatingVariableStoreAt: efiVarsURL)
    return loader
}

func makeStorage() throws -> [VZStorageDeviceConfiguration] {
    var devices: [VZStorageDeviceConfiguration] = [
        VZVirtioBlockDeviceConfiguration(attachment:
            try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false))
    ]
    if let seedURL {
        devices.append(VZVirtioBlockDeviceConfiguration(attachment:
            try VZDiskImageStorageDeviceAttachment(url: seedURL, readOnly: true)))
    }
    return devices
}

func makeNetwork() -> VZNetworkDeviceConfiguration {
    let net = VZVirtioNetworkDeviceConfiguration()
    net.attachment = VZNATNetworkDeviceAttachment()
    return net
}

var savedTermios: termios?

func makeConsole() -> VZSerialPortConfiguration {
    let port = VZVirtioConsoleDeviceSerialPortConfiguration()
    let input = FileHandle.standardInput
    let output = FileHandle.standardOutput

    if isatty(input.fileDescriptor) != 0 {
        var attrs = termios()
        tcgetattr(input.fileDescriptor, &attrs)
        savedTermios = attrs
        cfmakeraw(&attrs)
        tcsetattr(input.fileDescriptor, TCSANOW, &attrs)
        atexit {
            if var attrs = savedTermios {
                tcsetattr(FileHandle.standardInput.fileDescriptor, TCSANOW, &attrs)
            }
        }
    }

    port.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: input,
                                                       fileHandleForWriting: output)
    return port
}
