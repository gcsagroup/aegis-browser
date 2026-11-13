import Foundation
import os

/// Lifecycle states for the embedded Xray core used by `reality_vision`.
public enum AccessXrayRuntimeState: String, Sendable, Equatable {
    case idle
    case running
}

/// Starts and stops a pinned Xray core with a generated `reality_vision` config.
///
/// F8 scope:
/// - Verify the on-disk core digest against F6 pins before launch
/// - Launch through an injectable process controller
/// - Stop / terminate fail closed when not running
///
/// Out of scope: controlled-node probe (F10), inbound CONNECT (F4), WebKit.
public final class AccessXrayRuntime: @unchecked Sendable {
    public let architecture: AccessXrayArchitecture
    public let outboundProfile: AccessOutboundProfile

    private let processController: AccessXrayProcessControlling
    private let digestVerifier: AccessXrayDigestVerifying
    private let lock = OSAllocatedUnfairLock()
    private var handle: AccessXrayProcessHandle?
    private var stateValue: AccessXrayRuntimeState = .idle

    public init(
        architecture: AccessXrayArchitecture = .iosArm64,
        outboundProfile: AccessOutboundProfile = .realityVision,
        processController: AccessXrayProcessControlling,
        digestVerifier: AccessXrayDigestVerifying = AccessXrayPinnedDigestVerifier()
    ) throws {
        guard outboundProfile == .realityVision else {
            throw AccessXrayRuntimeError.profileNotAdmitted(outboundProfile.rawValue)
        }
        self.architecture = architecture
        self.outboundProfile = outboundProfile
        self.processController = processController
        self.digestVerifier = digestVerifier
    }

    public var state: AccessXrayRuntimeState {
        isRunning ? .running : .idle
    }

    /// True only while the launched handle still reports running.
    /// An independent core exit clears the cached state so a later start is admitted.
    public var isRunning: Bool {
        lock.lock()
        let active = handle
        let cached = stateValue
        lock.unlock()
        guard cached == .running, let active else { return false }
        if active.isRunning { return true }
        lock.lock()
        if handle === active {
            handle = nil
            stateValue = .idle
        }
        lock.unlock()
        return false
    }

    /// Verifies the executable digest, then launches with the supplied config.
    public func start(
        executableURL: URL,
        config: AccessRealityVisionOutboundConfig
    ) throws {
        guard config.profile == .realityVision else {
            throw AccessXrayRuntimeError.profileNotAdmitted(config.profile.rawValue)
        }

        if isRunning {
            throw AccessXrayRuntimeError.alreadyRunning
        }

        try digestVerifier.verify(
            fileURL: executableURL,
            architecture: architecture,
            outboundProfile: outboundProfile
        )

        let configData: Data
        do {
            configData = try config.jsonData()
        } catch {
            throw AccessXrayRuntimeError.configEncodingFailed
        }

        let launched: AccessXrayProcessHandle
        do {
            launched = try processController.launch(
                executableURL: executableURL,
                configData: configData
            )
        } catch {
            throw AccessXrayRuntimeError.launchFailed(String(describing: error))
        }

        lock.lock()
        if stateValue == .running {
            lock.unlock()
            launched.terminate()
            throw AccessXrayRuntimeError.alreadyRunning
        }
        handle = launched
        stateValue = .running
        lock.unlock()
    }

    /// Terminates the running process and returns to idle.
    /// A core that already exited is not running; callers may start again.
    public func stop() throws {
        guard isRunning else {
            throw AccessXrayRuntimeError.notRunning
        }
        lock.lock()
        guard let active = handle else {
            lock.unlock()
            throw AccessXrayRuntimeError.notRunning
        }
        handle = nil
        stateValue = .idle
        lock.unlock()
        active.terminate()
    }
}
