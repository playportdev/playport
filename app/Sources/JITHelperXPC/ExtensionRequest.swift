// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ObjectiveC
import Darwin

/// The private extension lifecycle used by the standalone activator. The existing
/// Playport caller keeps its own lifecycle until it can be verified on its build pipeline.
public final class JITExtensionRequest {
    private var ext: NSObject?
    private var identifier: NSUUID?

    public init(bundle: URL, endpoint: NSXPCListenerEndpoint) throws {
        guard let bundleID = Bundle(url: bundle)?.bundleIdentifier else { throw Self.failure("JIT helper не найден в сборке.") }
        guard let cls = NSClassFromString("NSExtension") else { throw Self.failure("NSExtension недоступен на этой iOS.") }
        let create = NSSelectorFromString("extensionWithIdentifier:error:")
        guard let method = class_getClassMethod(cls, create) else { throw Self.failure("Не удалось открыть JIT helper.") }
        typealias Create = @convention(c) (AnyClass, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> Unmanaged<NSObject>?
        var error: NSError?
        NSLog("Playport JIT: extension create %@", bundleID)
        guard let ext = unsafeBitCast(method_getImplementation(method), to: Create.self)(cls, create, bundleID as NSString, &error)?.takeUnretainedValue() else {
            throw Self.osFailure(stage: "Открытие JIT helper", error: error)
        }
        // Refuse to start a worker that this OS cannot terminate after a blocked native call.
        guard class_getInstanceMethod(type(of: ext), NSSelectorFromString("_kill:")) != nil else {
            throw Self.failure("На этой iOS недоступна остановка JIT helper.")
        }
        self.ext = ext
        let item = NSExtensionItem()
        item.userInfo = [jitHelperEndpointKey: endpoint]
        let begin = NSSelectorFromString("beginExtensionRequestWithInputItems:error:")
        guard let beginMethod = class_getInstanceMethod(type(of: ext), begin) else { throw Self.failure("Не удалось запустить JIT helper.") }
        typealias Begin = @convention(c) (NSObject, Selector, NSArray, AutoreleasingUnsafeMutablePointer<NSError?>) -> Unmanaged<NSUUID>?
        NSLog("Playport JIT: extension begin request %@", bundleID)
        guard let identifier = unsafeBitCast(method_getImplementation(beginMethod), to: Begin.self)(ext, begin, [item] as NSArray, &error)?.takeUnretainedValue() else {
            throw Self.osFailure(stage: "Запуск JIT helper", error: error)
        }
        self.identifier = identifier
        NSLog("Playport JIT: extension request created %@", identifier.uuidString)
    }

    /// Fallback if the worker does not service its immediate XPC cancel message.
    public func terminate() {
        guard let ext else { return }
        let selector = NSSelectorFromString("_kill:")
        guard let method = class_getInstanceMethod(type(of: ext), selector) else { return }
        typealias Kill = @convention(c) (NSObject, Selector, Int32) -> Void
        unsafeBitCast(method_getImplementation(method), to: Kill.self)(ext, selector, SIGKILL)
    }

    /// Called after remote XPC interruption or invalidation, so closing the request does not masquerade as worker termination.
    public func close() {
        guard let ext else { return }
        if let identifier {
            let selector = NSSelectorFromString("cancelExtensionRequestWithIdentifier:")
            if let method = class_getInstanceMethod(type(of: ext), selector) {
                typealias Cancel = @convention(c) (NSObject, Selector, NSUUID) -> Void
                unsafeBitCast(method_getImplementation(method), to: Cancel.self)(ext, selector, identifier)
            }
        }
        self.identifier = nil
        self.ext = nil
    }

    private static func osFailure(stage: String, error: NSError?) -> NSError {
        guard let error else { return failure("\(stage): iOS не вернула описание ошибки.") }
        var current: NSError? = error
        var depth = 0
        while let diagnostic = current, depth < 5 {
            NSLog("Playport JIT: %@ error[%d] %@ (%ld): %@", stage, depth,
                  diagnostic.domain, diagnostic.code, diagnostic.localizedDescription)
            current = diagnostic.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return failure("\(stage): \(error.localizedDescription) (\(error.domain), \(error.code))")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "PlayportJITExtension", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
