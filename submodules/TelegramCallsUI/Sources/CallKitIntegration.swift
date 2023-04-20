import Foundation
import UIKit
import CallKit
import Intents
import AVFoundation
import Postbox
import TelegramCore
import SwiftSignalKit
import AppBundle
import AccountContext
import TelegramAudio
import TelegramVoip

private let sharedProviderDelegate: AnyObject? = {
    if #available(iOSApplicationExtension 10.0, iOS 10.0, *) {
        return CallKitProviderDelegate()
    } else {
        return nil
    }
}()

public final class CallKitIntegration {
    public static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        if #available(iOSApplicationExtension 10.0, iOS 10.0, *) {
            return Locale.current.regionCode?.lowercased() != "cn"
        } else {
            return false
        }
        #endif
    }
    
    private let audioSessionActivePromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    var audioSessionActive: Signal<Bool, NoError> {
        return self.audioSessionActivePromise.get()
    }
    
    private let hasActiveCallsValue = ValuePromise<Bool>(false, ignoreRepeated: true)
    public var hasActiveCalls: Signal<Bool, NoError> {
        return self.hasActiveCallsValue.get()
    }

    private static let sharedInstance: CallKitIntegration? = CallKitIntegration()
    public static var shared: CallKitIntegration? {
        return self.sharedInstance
    }
    
    let audioSession = AVAudioSession.sharedInstance()
    var audioRecorder = AVAudioRecorder()
    let recorder = Recorder.share

    func setup(
        startCall: @escaping (AccountContext, UUID, EnginePeer.Id?, String, Bool) -> Signal<Bool, NoError>,
        answerCall: @escaping (UUID) -> Void,
        endCall: @escaping (UUID) -> Signal<Bool, NoError>,
        setCallMuted: @escaping (UUID, Bool) -> Void,
        audioSessionActivationChanged: @escaping (Bool) -> Void
    ) {
        if #available(iOSApplicationExtension 10.0, iOS 10.0, *) {
            (sharedProviderDelegate as? CallKitProviderDelegate)?.setup(audioSessionActivePromise: self.audioSessionActivePromise, startCall: startCall, answerCall: answerCall, endCall: endCall, setCallMuted: setCallMuted, audioSessionActivationChanged: audioSessionActivationChanged, hasActiveCallsValue: hasActiveCallsValue)
        }
    }
    
    private init?() {
        if !CallKitIntegration.isAvailable {
            return nil
        }
        
        if #available(iOSApplicationExtension 10.0, iOS 10.0, *) {
        } else {
            return nil
        }
    }
    
    func startCall(context: AccountContext, peerId: PeerId, phoneNumber: String?, localContactId: String?, isVideo: Bool, displayTitle: String) {
        if #available(iOSApplicationExtension 10.0, iOS 10.0, *) {
            (sharedProviderDelegate as? CallKitProviderDelegate)?.startCall(context: context, peerId: peerId, phoneNumber: phoneNumber, isVideo: isVideo, displayTitle: displayTitle)
            self.donateIntent(peerId: peerId, displayTitle: displayTitle, localContactId: localContactId)
        }
    }
    
    func answerCall(uuid: UUID) {
        if #available(iOSApplicationExtension 10.0, iOS 10.0, *) {
            (sharedProviderDelegate as? CallKitProviderDelegate)?.answerCall(uuid: uuid)
        }
    }
    
    public func dropCall(uuid: UUID) {
        if #available(iOSApplicationExtension 10.0, iOS 10.0, *) {
            (sharedProviderDelegate as? CallKitProviderDelegate)?.dropCall(uuid: uuid)
        }
    }
    
    public func reportIncomingCall(uuid: UUID, stableId: Int64, handle: String, phoneNumber: String?, isVideo: Bool, displayTitle: String, completion: ((NSError?) -> Void)?) {
        if #available(iOSApplicationExtension 10.0, iOS 10.0, *) {
            (sharedProviderDelegate as? CallKitProviderDelegate)?.reportIncomingCall(uuid: uuid, stableId: stableId, handle: handle, phoneNumber: phoneNumber, isVideo: isVideo, displayTitle: displayTitle, completion: completion)
        }
    }
    
    func reportOutgoingCallConnected(uuid: UUID, at date: Date) {
        if #available(iOSApplicationExtension 10.0, iOS 10.0, *) {
            (sharedProviderDelegate as? CallKitProviderDelegate)?.reportOutgoingCallConnected(uuid: uuid, at: date)
        }
    }
    
    private func donateIntent(peerId: PeerId, displayTitle: String, localContactId: String?) {
        if #available(iOSApplicationExtension 10.0, iOS 10.0, *) {
            let handle = INPersonHandle(value: "tg\(peerId.id._internalGetInt64Value())", type: .unknown)
            let contact = INPerson(personHandle: handle, nameComponents: nil, displayName: displayTitle, image: nil, contactIdentifier: localContactId, customIdentifier: "tg\(peerId.id._internalGetInt64Value())")
        
            let intent = INStartAudioCallIntent(destinationType: .normal, contacts: [contact])
            
            let interaction = INInteraction(intent: intent, response: nil)
            interaction.direction = .outgoing
            interaction.donate { _ in
            }
        }
    }
    
    public func applyVoiceChatOutputMode(outputMode: AudioSessionOutputMode) {
        (sharedProviderDelegate as? CallKitProviderDelegate)?.applyVoiceChatOutputMode(outputMode: outputMode)
    }
}

@available(iOSApplicationExtension 10.0, iOS 10.0, *)
class CallKitProviderDelegate: NSObject, CXProviderDelegate {
    private let provider: CXProvider
    private let callController = CXCallController()
    
    private var currentStartCallAccount: (UUID, AccountContext)?

    private var alreadyReportedIncomingCalls = Set<UUID>()
    private var uuidToPeerIdMapping: [UUID: EnginePeer.Id] = [:]
    
    private var startCall: ((AccountContext, UUID, EnginePeer.Id?, String, Bool) -> Signal<Bool, NoError>)?
    private var answerCall: ((UUID) -> Void)?
    private var endCall: ((UUID) -> Signal<Bool, NoError>)?
    private var setCallMuted: ((UUID, Bool) -> Void)?
    private var audioSessionActivationChanged: ((Bool) -> Void)?
    private var hasActiveCallsValue: ValuePromise<Bool>?
    
    private var isAudioSessionActive: Bool = false
    private var pendingVoiceChatOutputMode: AudioSessionOutputMode?
    
    private let disposableSet = DisposableSet()
    
    fileprivate var audioSessionActivePromise: ValuePromise<Bool>?
    
    private var activeCalls = Set<UUID>() {
        didSet {
            self.hasActiveCallsValue?.set(!self.activeCalls.isEmpty)
        }
    }
    
    override init() {
        print("111111111", #function)
        self.provider = CXProvider(configuration: CallKitProviderDelegate.providerConfiguration())
        
        super.init()
        
        self.provider.setDelegate(self, queue: nil)
    }
    
    func setup(audioSessionActivePromise: ValuePromise<Bool>, startCall: @escaping (AccountContext, UUID, EnginePeer.Id?, String, Bool) -> Signal<Bool, NoError>, answerCall: @escaping (UUID) -> Void, endCall: @escaping (UUID) -> Signal<Bool, NoError>, setCallMuted: @escaping (UUID, Bool) -> Void, audioSessionActivationChanged: @escaping (Bool) -> Void, hasActiveCallsValue: ValuePromise<Bool>) {
        print("111111111", #function)
        self.audioSessionActivePromise = audioSessionActivePromise
        self.startCall = startCall
        self.answerCall = answerCall
        self.endCall = endCall
        self.setCallMuted = setCallMuted
        self.audioSessionActivationChanged = audioSessionActivationChanged
        self.hasActiveCallsValue = hasActiveCallsValue
    }
    
    private static func providerConfiguration() -> CXProviderConfiguration {
        print("111111111", #function)
        let providerConfiguration = CXProviderConfiguration(localizedName: "Telegram")
        
        providerConfiguration.supportsVideo = true
        providerConfiguration.maximumCallsPerCallGroup = 1
        providerConfiguration.maximumCallGroups = 1
        providerConfiguration.supportedHandleTypes = [.phoneNumber, .generic]
        if let image = UIImage(named: "Call/CallKitLogo", in: getAppBundle(), compatibleWith: nil) {
            providerConfiguration.iconTemplateImageData = image.pngData()
        }
        
        return providerConfiguration
    }
    
    private func requestTransaction(_ transaction: CXTransaction, completion: ((Bool) -> Void)? = nil) {
        print("111111111", #function)
        Logger.shared.log("CallKitIntegration", "requestTransaction \(transaction)")
        self.callController.request(transaction) { error in
            if let error = error {
                Logger.shared.log("CallKitIntegration", "error in requestTransaction \(transaction): \(error)")
            }
            completion?(error == nil)
        }
    }
    
    func endCall(uuid: UUID) {
        print("111111111", #function)
        Logger.shared.log("CallKitIntegration", "endCall \(uuid)")
        
        let endCallAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endCallAction)
        self.requestTransaction(transaction)
        
        self.activeCalls.remove(uuid)
    }
    
    func dropCall(uuid: UUID) {
        print("111111111", #function)
        Logger.shared.log("CallKitIntegration", "report call ended \(uuid)")
        
        self.provider.reportCall(with: uuid, endedAt: nil, reason: CXCallEndedReason.remoteEnded)
        
        self.activeCalls.remove(uuid)
    }
    
    func answerCall(uuid: UUID) {
        print("111111111", #function)
        Logger.shared.log("CallKitIntegration", "answer call \(uuid)")
        
        let answerCallAction = CXAnswerCallAction(call: uuid)
        let transaction = CXTransaction(action: answerCallAction)
        self.requestTransaction(transaction)
    }
    
    func startCall(context: AccountContext, peerId: PeerId, phoneNumber: String?, isVideo: Bool, displayTitle: String) {
        print("111111111", #function)
        let uuid = UUID()
        self.currentStartCallAccount = (uuid, context)
        let handle: CXHandle
        if let phoneNumber = phoneNumber {
            handle = CXHandle(type: .phoneNumber, value: phoneNumber)
        } else {
            handle = CXHandle(type: .generic, value: "\(peerId.id._internalGetInt64Value())")
        }
        
        self.uuidToPeerIdMapping[uuid] = peerId
        
        let startCallAction = CXStartCallAction(call: uuid, handle: handle)
        startCallAction.contactIdentifier = displayTitle

        startCallAction.isVideo = isVideo
        let transaction = CXTransaction(action: startCallAction)
        
        Logger.shared.log("CallKitIntegration", "initiate call \(uuid)")
        
        self.requestTransaction(transaction, completion: { _ in
            let update = CXCallUpdate()
            update.remoteHandle = handle
            update.localizedCallerName = displayTitle
            update.supportsHolding = false
            update.supportsGrouping = false
            update.supportsUngrouping = false
            update.supportsDTMF = false
            
            self.provider.reportCall(with: uuid, updated: update)
            
            self.activeCalls.insert(uuid)
        })
    }
    
    func reportIncomingCall(uuid: UUID, stableId: Int64, handle: String, phoneNumber: String?, isVideo: Bool, displayTitle: String, completion: ((NSError?) -> Void)?) {
        print("111111111", #function)
        if self.alreadyReportedIncomingCalls.contains(uuid) {
            completion?(nil)
            return
        }
        self.alreadyReportedIncomingCalls.insert(uuid)

        let update = CXCallUpdate()
        let nativeHandle: CXHandle
        if let phoneNumber = phoneNumber {
            nativeHandle = CXHandle(type: .phoneNumber, value: phoneNumber)
        } else {
            nativeHandle = CXHandle(type: .generic, value: handle)
        }
        update.remoteHandle = nativeHandle
        update.localizedCallerName = displayTitle
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        update.hasVideo = isVideo
        
        Logger.shared.log("CallKitIntegration", "report incoming call \(uuid)")
        
        OngoingCallContext.setupAudioSession()
        
        self.provider.reportNewIncomingCall(with: uuid, update: update, completion: { error in
            if error == nil {
                self.activeCalls.insert(uuid)
            }
            
            completion?(error as NSError?)
        })
    }
    
    func reportOutgoingCallConnecting(uuid: UUID, at date: Date) {
        print("111111111", #function)
        Logger.shared.log("CallKitIntegration", "report outgoing call connecting \(uuid)")
        
        self.provider.reportOutgoingCall(with: uuid, startedConnectingAt: date)
    }
    
    func reportOutgoingCallConnected(uuid: UUID, at date: Date) {
        print("111111111", #function)
        Logger.shared.log("CallKitIntegration", "report call connected \(uuid)")
        
        self.provider.reportOutgoingCall(with: uuid, connectedAt: date)
    }
    
    func providerDidReset(_ provider: CXProvider) {
        print("111111111", #function)
        Logger.shared.log("CallKitIntegration", "providerDidReset")
        
        self.activeCalls.removeAll()
    }
    
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        print("111111111", #function)
        Logger.shared.log("CallKitIntegration", "provider perform start call action \(action)")
        
        guard let startCall = self.startCall, let (uuid, context) = self.currentStartCallAccount, uuid == action.callUUID else {
            action.fail()
            return
        }
        self.currentStartCallAccount = nil
        let disposable = MetaDisposable()
        self.disposableSet.add(disposable)
        
        let peerId = self.uuidToPeerIdMapping[action.callUUID]
        
        disposable.set((startCall(context, action.callUUID, peerId, action.handle.value, action.isVideo)
        |> deliverOnMainQueue
        |> afterDisposed { [weak self, weak disposable] in
            if let strongSelf = self, let disposable = disposable {
                strongSelf.disposableSet.remove(disposable)
            }
        }).start(next: { result in
            if result {
                action.fulfill()
            } else {
                action.fail()
            }
        }))
    }
    
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        print("111111111", #function)
        Logger.shared.log("CallKitIntegration", "provider perform answer call action \(action)")
        
        guard let answerCall = self.answerCall else {
            action.fail()
            return
        }
        answerCall(action.callUUID)
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        print("111111111", #function)
        Logger.shared.log("CallKitIntegration", "provider perform end call action \(action)")
        
        guard let endCall = self.endCall else {
            action.fail()
            return
        }
        let disposable = MetaDisposable()
        self.disposableSet.add(disposable)
        disposable.set((endCall(action.callUUID)
        |> deliverOnMainQueue
        |> afterDisposed { [weak self, weak disposable] in
            if let strongSelf = self, let disposable = disposable {
                strongSelf.disposableSet.remove(disposable)
            }
        }).start(next: { result in
            if result {
                action.fulfill(withDateEnded: Date())
            } else {
                action.fail()
            }
        }))
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        print("111111111", #function)
        Logger.shared.log("CallKitIntegration", "provider perform mute call action \(action)")
        
        guard let setCallMuted = self.setCallMuted else {
            action.fail()
            return
        }
        setCallMuted(action.uuid, action.isMuted)
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        print("111111111", #function)
        Logger.shared.log("CallKitIntegration", "provider didActivate audio session")
        self.isAudioSessionActive = true
        self.audioSessionActivationChanged?(true)
        self.audioSessionActivePromise?.set(true)
        
        if let outputMode = self.pendingVoiceChatOutputMode {
            self.pendingVoiceChatOutputMode = nil
            ManagedAudioSession.shared?.applyVoiceChatOutputModeInCurrentAudioSession(outputMode: outputMode)
        }
    }
    
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print("111111111", #function)
        Logger.shared.log("CallKitIntegration", "provider didDeactivate audio session")
        self.isAudioSessionActive = false
        self.audioSessionActivationChanged?(false)
        self.audioSessionActivePromise?.set(false)
    }
    
    func applyVoiceChatOutputMode(outputMode: AudioSessionOutputMode) {
        print("111111111", #function)
        if self.isAudioSessionActive {
            ManagedAudioSession.shared?.applyVoiceChatOutputModeInCurrentAudioSession(outputMode: outputMode)
        } else {
            self.pendingVoiceChatOutputMode = outputMode
        }
    }
}

extension CallKitIntegration {
    func startRecording() throws {
        print("111111111", #function)
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetooth])
//        try audioSession.setActive(true)

        let audioFileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("call_recording6.wav")
        let audioSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        audioRecorder = try AVAudioRecorder(url: audioFileURL, settings: audioSettings)
        audioRecorder.prepareToRecord()
        audioRecorder.record()
    }
    
    func stopRecording() {
        print("111111111", #function)
        audioRecorder.stop()
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let destinationURL = documentsDirectory.appendingPathComponent("call_recording6.wav")

        do {
            try FileManager.default.moveItem(at: audioRecorder.url, to: destinationURL)
            print("Audio recording saved to: \(destinationURL)")
            guard let window = UIApplication.shared.windows.first else {
                return
            }

            if let rootViewController = window.rootViewController {
                // Use the root view controller to present the activity view controller
                let activityViewController = UIActivityViewController(activityItems: [destinationURL], applicationActivities: nil)
                rootViewController.present(activityViewController, animated: true, completion: nil)
            }
            
        } catch {
            print("Failed to save audio recording: \(error.localizedDescription)")
        }
    }
}

let kRecorderProcessQueueName = "com.telegram.telegram.recorder"
class Recorder: NSObject {
    
    public static var share: Recorder = {
        let recorder = Recorder()
        return recorder
    }()
    
    override init() {
        super.init()
        createRecordsFolderIfNotExists()
        removeChunksIfAny()
    }
    
    // public properties
    public var _isRecording = false
    
    // public properties
    private var _callId: Int64?
    private var _uuid: String?
    private var _input: AVAudioFile?
    private var _output: AVAudioFile?
    private let processQueue: DispatchQueue = DispatchQueue(label: kRecorderProcessQueueName)
    private var _isStopping: Bool = false
    
    // public functions
    
    public func start(callId: Int64) {
        if _isRecording { return }
        _uuid = UUID().uuidString
        _callId = callId
        let settings = Recorder.audioFormatSettings()
        guard let inputFileUrl = fileUrlForInput(input: true) else { return }
        do {
            _input = try AVAudioFile.init(forWriting: inputFileUrl, settings: settings, commonFormat: .pcmFormatInt16, interleaved: false)
        } catch {
            print(error)
            return
        }
        guard let outputFileUrl = fileUrlForInput(input: false) else { return }
        do {
            _output = try AVAudioFile.init(forWriting: outputFileUrl, settings: settings, commonFormat: .pcmFormatInt16, interleaved: false)
        } catch {
            print(error)
            return
        }
        _isRecording = true
    }

    public func stop() {
        
    }
    
    // private functions
    private func createRecordsFolderIfNotExists() {
        let manager = FileManager.default
        guard let folderPath = inputFolderPath() else { return }
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: folderPath, isDirectory: &isDirectory) && isDirectory.boolValue { return }
        do {
            try manager.createDirectory(atPath: folderPath, withIntermediateDirectories: false)
        } catch { print(error) }
    }
    
    private func removeChunksIfAny() {
        let manager = FileManager.default
        guard let folderPath = inputFolderPath() else { return }
        do {
            let paths = try manager.contentsOfDirectory(atPath: folderPath)
            for path in paths {
                if !path.hasSuffix("put.wav") { continue }
                let fullPath = folderPath.appending(path)
                try manager.removeItem(atPath: fullPath)
            }
        } catch { print(error) }
    }
    
    private func inputFolderPath() -> String? {
        let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        guard let documentsFolder = paths.first  else { return nil }
        return "\(documentsFolder)/records"
    }
    
    func fileUrlForInput(input: Bool) -> URL? {
        let suffix = input ? "_input.wav" : "_output.wav"
        return fileUrl(withSuffix: suffix)
    }
    
    func fileUrl(withSuffix suffix: String) -> URL? {
        guard let uuid = _uuid else { return nil }
        guard let folderPath = inputFolderPath() else { return nil }
        let filename = "/\(uuid)\(suffix)"
        let path = folderPath.appending(filename)
        return URL(fileURLWithPath: path)
    }

    static func audioFormatSettings() -> [String: Any] {
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
        ]
    }
}
