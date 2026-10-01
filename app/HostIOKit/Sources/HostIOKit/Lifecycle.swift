// SPDX-License-Identifier: GPL-3.0-or-later
/// What the app does for the runtime on each lifecycle event, and in which order
/// (quiesce the audio session, clear held controls on interruption, keep
/// runtime work off the main thread).
///
/// The rules:
/// - Focus loss goes to Wine first, while the held keys are still down, then
///   every held key, mouse button and pad control is released. A desktop game
///   sees WM_KILLFOCUS with the key down, then the key come up; it must never
///   keep a key down that the player let go of while the app was away. Keys and
///   mouse buttons are released through Winios's ring, behind the focus event;
///   pad controls are released by Winios's drain itself, once the loss has
///   reached the game (patches/madeira-winios/0003-Winios-deliver-focus-changes-on-the-window-s-owner-t.patch), so
///   there is no pad action here.
/// - Leaving the foreground does not by itself stop audio: Control Center or a
///   notification over the app leaves it playing. Going to the background, or
///   an audio-session interruption (Siri, a call), stops the output units, so
///   the game's WASAPI clock stalls rather than running on unheard.
/// - The in-game menu (InGameMenu.swift) stops audio while it is up, as the
///   game behind it is paused; audio comes back only when the app is active,
///   in the foreground, not interrupted and the menu is closed, whichever of
///   those clears last.
/// - Going to the background closes the GPU gate before anything else, and
///   coming back to the foreground opens it. iOS refuses GPU work from a
///   background app: a Metal command buffer committed after the
///   didEnterBackground handler returns runs nothing, and the game is not told
///   (a readback came back all zero after the 2026-09-24 pad session's third
///   trip to the Home Screen). While the gate is closed, DXMT's commits wait,
///   so the game stalls instead of losing work
///   (docs/ARCHITECTURE.md, background GPU gate).
///   Leaving the foreground alone does not close it: an inactive app that is
///   still on screen may use the GPU.
public enum LifecycleEvent: Equatable, Sendable {
    case resignActive, becomeActive, enterBackground, enterForeground
    case interruptionBegan
    case interruptionEnded
    /// AVAudioSession's media services restarted: every audio unit is gone.
    case mediaServicesReset
    /// Playport's in-game menu opened over the game, or closed.
    case menuOpened, menuClosed
}

public enum LifecycleAction: Equatable, Sendable {
    /// winios_post_focus
    case focus(Bool)
    /// winios_post_key(vk, 0) for each, in this order
    case releaseKeys([UInt8])
    /// winios_pointer(0, 0, flags, 0) for each MOUSEEVENTF_*UP flag
    case releaseButtons([UInt32])
    /// ios_audio_host_suspend(1); then AVAudioSession.setActive(false) when deactivate
    case suspendAudio(deactivate: Bool)
    /// AVAudioSession.setActive(true), then ios_audio_host_suspend(0); off the main thread
    case resumeAudio
    /// winemetal_host_gpu_gate: false closes it, on the main thread before the
    /// didEnterBackground handler returns; true opens it
    case gpu(Bool)
}

public struct Lifecycle {
    public private(set) var active = true
    public private(set) var background = false
    public private(set) var interrupted = false
    public private(set) var menu = false
    public private(set) var audioSuspended = false
    public private(set) var gpuHeld = false
    private var keys: [UInt8] = []        // held, in press order
    private var buttons: [UInt32] = []    // MOUSEEVENTF_*UP of the held buttons

    public init() {}

    /// A key went down. False when it was already held (a key repeat), which is
    /// not forwarded again.
    public mutating func keyDown(_ vk: UInt8) -> Bool {
        if keys.contains(vk) { return false }
        keys.append(vk)
        return true
    }

    /// A key came up. False when it was not held (it was already released on
    /// the way out of the foreground), which is not forwarded again.
    public mutating func keyUp(_ vk: UInt8) -> Bool {
        guard let i = keys.firstIndex(of: vk) else { return false }
        keys.remove(at: i)
        return true
    }

    /// A mouse button went down; upFlag is the MOUSEEVENTF_*UP that releases it.
    public mutating func buttonDown(upFlag: UInt32) -> Bool {
        if buttons.contains(upFlag) { return false }
        buttons.append(upFlag)
        return true
    }

    public mutating func buttonUp(upFlag: UInt32) -> Bool {
        guard let i = buttons.firstIndex(of: upFlag) else { return false }
        buttons.remove(at: i)
        return true
    }

    public var heldKeys: [UInt8] { keys }

    public mutating func handle(_ event: LifecycleEvent) -> [LifecycleAction] {
        var out: [LifecycleAction] = []
        switch event {
        case .resignActive:
            guard active else { return [] }
            active = false
            out.append(.focus(false))
            if !keys.isEmpty { out.append(.releaseKeys(keys)); keys = [] }
            if !buttons.isEmpty { out.append(.releaseButtons(buttons)); buttons = [] }
        case .becomeActive:
            guard !active else { return [] }
            active = true
            out.append(.focus(true))
            out += resumeIfDue()
        case .enterBackground:
            guard !background else { return [] }
            background = true
            if !gpuHeld { gpuHeld = true; out.append(.gpu(false)) }
            if !audioSuspended { audioSuspended = true; out.append(.suspendAudio(deactivate: true)) }
        case .enterForeground:
            guard background else { return [] }
            background = false
            if gpuHeld { gpuHeld = false; out.append(.gpu(true)) }
            out += resumeIfDue()
        case .interruptionBegan:
            guard !interrupted else { return [] }
            interrupted = true
            // The system has already deactivated the session; only the units stop.
            if !audioSuspended { audioSuspended = true; out.append(.suspendAudio(deactivate: false)) }
        case .interruptionEnded:
            guard interrupted else { return [] }
            interrupted = false
            out += resumeIfDue()
        case .mediaServicesReset:
            // The units are gone with the old media server; resuming restarts
            // nothing the game still holds. Recorded, not repaired.
            if !audioSuspended { audioSuspended = true; out.append(.suspendAudio(deactivate: false)) }
            out += resumeIfDue()
        case .menuOpened:
            guard !menu else { return [] }
            menu = true
            // The session stays active: the menu is in front and closes back into the game.
            if !audioSuspended { audioSuspended = true; out.append(.suspendAudio(deactivate: false)) }
        case .menuClosed:
            guard menu else { return [] }
            menu = false
            out += resumeIfDue()
        }
        return out
    }

    private mutating func resumeIfDue() -> [LifecycleAction] {
        guard audioSuspended, active, !background, !interrupted, !menu else { return [] }
        audioSuspended = false
        return [.resumeAudio]
    }
}
