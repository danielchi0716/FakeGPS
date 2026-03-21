import Foundation
import IOKit
import IOKit.usb

/// Monitors USB device attach/detach events using IOKit notifications.
/// Must be kept alive for the entire duration of monitoring — `deinit` cleans up IOKit resources.
final class USBWatcher {
    private var notificationPort: IONotificationPortRef?
    private var matchIterator: io_iterator_t = 0
    private var removeIterator: io_iterator_t = 0
    private let onDeviceChange: () -> Void

    init(onDeviceChange: @escaping () -> Void) {
        self.onDeviceChange = onDeviceChange
        start()
    }

    deinit {
        stop()
    }

    // MARK: - Private

    private func start() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port

        let runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        let context = Unmanaged.passUnretained(self).toOpaque()

        // On modern macOS, iPhone registers as "AppleUSBDevice" (not IOUSBDevice/IOUSBHostDevice).
        // No vendor filter — kUSBVendorID matching is not supported on AppleUSBDevice.
        // Extra events from non-iPhone USB devices are harmless due to debouncing.
        guard let matchDict = IOServiceMatching("AppleUSBDevice") as NSMutableDictionary? else { return }

        // Need a separate copy for the second registration (IOKit consumes the dictionary)
        guard let removeDict = matchDict.mutableCopy() as? NSMutableDictionary else { return }

        // Shared callback for both attach and detach
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<USBWatcher>.fromOpaque(refcon).takeUnretainedValue()
            watcher.drainIterator(iterator)
            watcher.onDeviceChange()
        }

        // Register for attach notifications
        IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            matchDict,
            callback,
            context,
            &matchIterator
        )
        drainIterator(matchIterator)

        // Register for detach notifications
        IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            removeDict,
            callback,
            context,
            &removeIterator
        )
        drainIterator(removeIterator)
    }

    func stop() {
        if matchIterator != 0 {
            IOObjectRelease(matchIterator)
            matchIterator = 0
        }
        if removeIterator != 0 {
            IOObjectRelease(removeIterator)
            removeIterator = 0
        }
        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
    }

    private func drainIterator(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            IOObjectRelease(service)
        }
    }
}
