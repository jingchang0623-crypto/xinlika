// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation
@preconcurrency import CoreBluetooth

public struct Discovered: Sendable {
    public let peripheral: CBPeripheral
    public let name: String
    public let rssi: Int
    public let byService: Bool
}

public enum BLEError: Error, CustomStringConvertible {
    case bluetoothUnavailable(String)
    case notFound
    case connectFailed(String)
    case missingCharacteristic(String)
    case notConnected

    public var description: String {
        switch self {
        case .bluetoothUnavailable(let s): return "蓝牙不可用：\(s)"
        case .notFound: return "没找到录音笔"
        case .connectFailed(let s): return "连接失败：\(s)"
        case .missingCharacteristic(let s): return "设备缺少特征 \(s)"
        case .notConnected: return "尚未连接"
        }
    }
}

/// Opt-in, local capture tap. The normal app continues to discard live audio.
/// A receiver must enqueue bounded work and return immediately: this runs on the BLE queue.
public struct BLEFrameObservation: Sendable {
    public let connectionID: UUID
    public let source: String
    public let frame: Proto.Frame
    public let receivedAt: Date
    public let uptime: TimeInterval

    public init(connectionID: UUID, source: String, frame: Proto.Frame,
                receivedAt: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.connectionID = connectionID
        self.source = source
        self.frame = frame
        self.receivedAt = receivedAt
        self.uptime = uptime
    }
}

public struct BLENotificationObservation: Sendable {
    public let connectionID: UUID
    public let source: String
    public let isNotifying: Bool
    public let error: String?
}

/// CoreBluetooth 封装。AE22 / AE23 各用一个 FrameParser——两路字节交织会毁掉半帧。
public final class BLEClient: NSObject, @unchecked Sendable {
    private var central: CBCentralManager!
    private let queue = DispatchQueue(label: "luyinbi.ble")
    private let lock = NSLock()

    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var parsers: [String: FrameParser] = [
        "AE22": FrameParser(name: "AE22"), "AE23": FrameParser(name: "AE23")]

    private var pending: [(source: String, frame: Proto.Frame)] = []
    private let recordingReplies = RecordingReplySlot()
    private var recordingDiagnosticHandler: (@Sendable (RecordingDiagnosticEvent) -> Void)?
    private var frameObserver: (@Sendable (BLEFrameObservation) -> Void)?
    private var notificationObserver: (@Sendable (BLENotificationObservation) -> Void)?
    private var notificationStatus: [String: Bool] = [:]
    private var captureConnectionID = UUID()
    private var liveAudioFrames = 0
    /// Legacy received-live-frame counter. The normal app discards these bytes;
    /// an explicit onFrameObservation subscriber may persist its own bounded copy.
    public var discardedLiveAudioFrameCount: Int {
        lock.lock(); defer { lock.unlock() }; return liveAudioFrames
    }
    public var onRecordingDiagnostic: (@Sendable (RecordingDiagnosticEvent) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return recordingDiagnosticHandler }
        set { lock.lock(); recordingDiagnosticHandler = newValue; lock.unlock() }
    }
    public var onFrameObservation: (@Sendable (BLEFrameObservation) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return frameObserver }
        set { lock.lock(); frameObserver = newValue; lock.unlock() }
    }
    public var onNotificationObservation: (@Sendable (BLENotificationObservation) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return notificationObserver }
        set { lock.lock(); notificationObserver = newValue; lock.unlock() }
    }
    public var notificationStates: [String: Bool] {
        lock.lock(); defer { lock.unlock() }; return notificationStatus
    }
    private var waiter: CheckedContinuation<Void, Never>?
    // 用闭包而不是直接存 continuation：delegate 可能被多次回调，闭包置 nil 后重复回调是空操作
    private var connectWaiter: ((Result<Void, Error>) -> Void)?
    private var discoverWaiter: ((Result<Void, Error>) -> Void)?
    private var connectAttempt = UUID()
    private var discoverAttempt = UUID()
    private var notifyReady = 0
    private var requireKeyNotifications = false
    private var wireBytes: [String: Int] = [:]
    public var transportByteCounts: [String: Int] {
        lock.lock(); defer { lock.unlock() }; return wireBytes
    }
    private var discovered: [ObjectIdentifier: Discovered] = [:]
    private var seq: UInt8 = 0

    /// 广播流的订阅者。多个消费者各持一个 continuation，靠 UUID 认领自己那一个，
    /// 这样谁取消谁退场，不会影响别人。
    private var advSinks: [UUID: AsyncStream<Discovered>.Continuation] = [:]
    /// 正在跑的 scan(seconds:) 个数。扫描是全局的，只有「没有定时扫描、也没有广播流订阅者」
    /// 时才真的 stopScan——否则一次 scan() 结束会顺手掐掉别人的持续监听。
    private var timedScanDepth = 0

    /// 正在等系统确认断开的 peripheral。cancelPeripheralConnection 是异步的，
    /// 这个字段就是「已经喊了断，但系统还没回话」这段中间态。
    private var disconnecting: CBPeripheral?
    /// 等「断干净」的人。connect() 会排在这里，避免拿到一条还没真断的连接。
    private var settleWaiters: [() -> Void] = []
    private var disconnectHandler: (@Sendable (Error?) -> Void)?
    public var onRestore: (@Sendable (UUID) -> Void)?
    public var onPoweredOn: (@Sendable () -> Void)?
    public var onConnectAvailable: (@Sendable (UUID) -> Void)?
    public private(set) var restoredIdentifier: UUID?

    public private(set) var mtu: Int = 0

    /// 意外断连回调（录音笔走开、没电、被手机 App 抢走）。
    /// **只在非主动断连时触发**：我们自己调 disconnect() 属于正常收尾，
    /// 再回调一次只会让上层误判成「设备掉了」。
    /// 回调在蓝牙队列上执行，别在里面做重活，也别假设自己在主线程。
    public var onDisconnect: (@Sendable (Error?) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return disconnectHandler }
        set { lock.lock(); disconnectHandler = newValue; lock.unlock() }
    }

    /// 当前是否持有一条活着的连接。断连回调到达后立刻变 false。
    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return central?.state == .poweredOn && peripheral?.state == .connected && writeChar != nil
    }
    public var connectedIdentifier: UUID? {
        lock.lock(); defer { lock.unlock() }
        return peripheral?.state == .connected ? peripheral?.identifier : nil
    }
    public var connectionIdentifier: UUID {
        lock.lock(); defer { lock.unlock() }; return captureConnectionID
    }

    public override init() {
        super.init()
        #if os(iOS)
        central = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "org.xinlika.app.ble.v1"]) // gitleaks:allow -- Public CoreBluetooth state-restoration identifier.
        #else
        central = CBCentralManager(delegate: self, queue: queue)
        #endif
    }

    public func knownDevice(_ id: UUID) -> Discovered? {
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else { return nil }
        return Discovered(peripheral: p, name: p.name ?? "灵魂卡", rssi: 0, byService: true)
    }

    // MARK: - 扫描
    public func waitPoweredOn(timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while central.state != .poweredOn && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try Task.checkCancellation()
        guard central.state == .poweredOn else {
            let reason: String
            switch central.state {
            case .poweredOff: reason = "请在系统设置中开启蓝牙"
            case .unauthorized: reason = "请在系统设置中允许深脑使用蓝牙"
            case .unsupported: reason = "当前系统不支持蓝牙连接"
            default: reason = "蓝牙尚未就绪，请稍后重试"
            }
            throw BLEError.bluetoothUnavailable(reason)
        }
    }

    public func scan(seconds: TimeInterval = 8, nameHint: String = "") async throws -> [Discovered] {
        try await waitPoweredOn()
        clearDiscovered()
        noteTimedScanBegan()
        // 不限定服务：部分固件广播里不带 AE20，靠名字兜底
        beginScanning()
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        // 只有在没人监听广播流时才真停扫描（见 timedScanDepth 注释）
        if noteTimedScanEnded() { central.stopScan() }
        let all = snapshotDiscovered()
        return all.sorted {
            $0.byService != $1.byService ? $0.byService : $0.rssi > $1.rssi
        }
    }

    /// 持续广播流：扫描一直开着，didDiscover 一来就推给消费者。
    ///
    /// 与 scan(seconds:) 的区别是语义——scan 是「扫一段时间给我一张去重后的名单」，
    /// 这里是「设备每响一次都告诉我」，所以同一台设备会反复出现，RSSI 每次都是新的。
    /// 上层要自己做去重 / 冷却，别指望流帮你收敛。
    ///
    /// 支持多个消费者；消费者的任务被取消或者流被丢弃时，onTermination 会摘掉自己，
    /// 最后一个走人时自动 stopScan。
    public func advertisements() -> AsyncStream<Discovered> {
        let id = UUID()
        return AsyncStream<Discovered> { cont in
            // 先挂终止回调再登记，顺序反了理论上没差（build 闭包同步执行，
            // 这中间不可能收到终止），但这样读起来更像「注册-注销」成对出现。
            cont.onTermination = { [weak self] _ in self?.removeSink(id) }
            addSink(id, cont)
            // 蓝牙还没 poweredOn 时这里是空操作，centralManagerDidUpdateState 会补上
            beginScanning()
        }
    }

    public func findRecorder(seconds: TimeInterval = 8, name: String = "CB08") async throws -> Discovered {
        let all = try await scan(seconds: seconds, nameHint: name)
        if let hit = all.first(where: { $0.byService }) { return hit }
        if let hit = all.first(where: { $0.name.lowercased().contains(name.lowercased()) }) { return hit }
        throw BLEError.notFound   // 绝不盲连列表里第一个——那可能是你自己的电脑或耳机
    }

    // MARK: - 连接
    public func connect(_ device: Discovered, synchronizeClock: Bool = true, restoring: Bool = false, requireKeyNotifications: Bool = false) async throws {
        try Task.checkCancellation()
        if device.peripheral.state == .connected && !restoring { disconnect() }
        // 「断开 → 立刻重连」的竞态：cancelPeripheralConnection 只是提交请求，
        // 不等系统确认就 connect，可能复用上一条还没真断的连接——
        // 拿到的服务 / 特征还是旧的，notify 也不会重新起。
        await waitDisconnectSettled(timeout: 2)
        try Task.checkCancellation()
        let p = device.peripheral
        p.delegate = self
        // 回调一律在锁外发（prepareForConnect 里已经解锁）
        for f in prepareForConnect(p) { f() }
        lock.lock(); self.requireKeyNotifications = requireKeyNotifications; lock.unlock()
        if p.state != .connected { try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let attempt = UUID()
            lock.lock(); connectAttempt = attempt; connectWaiter = { r in c.resume(with: r) }; lock.unlock()
            central.connect(p, options: nil)
            queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                self?.finishConnect(.failure(BLEError.connectFailed("连接超时")), attempt: attempt)
            }
        } }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let attempt = UUID()
            lock.lock(); discoverAttempt = attempt; discoverWaiter = { r in c.resume(with: r) }; lock.unlock()
            p.discoverServices([CBUUID(string: Proto.serviceMain)])
            queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                self?.finishDiscover(.failure(BLEError.connectFailed("服务发现超时")), attempt: attempt)
            }
        }
        mtu = p.maximumWriteValueLength(for: .withoutResponse) + 3
        try Task.checkCancellation()
        // 每次连接（含下载重连/系统恢复后的连接）都校时，早于调用方查询或下载。
        // 此时 AE21/AE22 已就绪；0-0 无应答，不等待或消费其他命令的通知帧。
        // A capture experiment must not alter the recorder's clock at a reconnect/rollover.
        if synchronizeClock { try syncTime() }
    }

    /// 主动断开。签名保持同步不变（上层在 defer 里调，await 不了）。
    ///
    /// 与改造前的区别：这里只把「对外可见的连接状态」立刻清掉（sendRaw 马上抛 notConnected，
    /// 与以前一致），真正的收尾等 didDisconnectPeripheral。中间这段被记在 disconnecting 上，
    /// 紧接着的 connect() 会先等它落定。
    public func disconnect() {
        guard let p = beginDisconnect() else { return }
        central.cancelPeripheralConnection(p)
        // An intentional disconnect is filtered out by didDisconnectPeripheral. Wake pending
        // connect/discovery here so a user pause does not wait for their twelve-second timers.
        finishConnect(.failure(CancellationError()))
        finishDiscover(.failure(CancellationError()))
    }

    // MARK: - 收发
    public func nextSeq() -> UInt8 { lock.lock(); seq &+= 1; let s = seq; lock.unlock(); return s }

    /// 整帧一次写入。绝不在应用层分包——2-2 / 2-8 拆包设备会解析错文件名。
    public func sendRaw(_ frame: [UInt8]) throws {
        guard let p = peripheral, let c = writeChar else { throw BLEError.notConnected }
        p.writeValue(Data(frame), for: c, type: .withoutResponse)
    }

    public func send(_ type: UInt8, _ cmd: UInt8, _ params: [UInt8] = []) throws {
        try sendRaw(Proto.buildFrame(type, cmd, params, seq: nextSeq()))
    }

    /// No boolean ACK is defined for these commands; the caller reads back card state.
    public func sendRecording(_ action: RecorderAction) throws {
        guard isConnected else { throw BLEError.notConnected }
        let seq = nextSeq()
        try sendRaw(action.frame(sequence: seq))
        let frame = Proto.Frame(seq: seq, data: [Proto.T.audio, action.request] + action.parameters)
        if let event = RecordingDiagnosticEvent(phase: "tx", source: "AE21", frame: frame) { onRecordingDiagnostic?(event) }
    }

    /// 取下一帧，超时返回 nil。
    ///
    /// 注意这里**故意不因为断连提前返回 nil**：download / fileList 都是
    /// 「nextFrame 返回 nil 就立刻再问一次」的循环，靠 idleTimeout 收尾。
    /// 断连后如果每次都秒回 nil，那个循环就变成空转跑满一个核，一直烧到 idleTimeout。
    /// 想第一时间知道断连，用 onDisconnect / isConnected，别指望 nextFrame。
    public func nextFrame(timeout: TimeInterval) async -> (source: String, frame: Proto.Frame)? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let f = popPending() { return f }
            if Date() >= deadline { return nil }
            // 不能用 try?：任务被取消后 Task.sleep 立刻抛出并返回，
            // 这个 while 就变成空转跑满一个核，一直烧到超时为止。
            do { try await Task.sleep(nanoseconds: 15_000_000) }
            catch { return nil }
        }
    }

    public func expect(_ type: UInt8, _ cmd: UInt8, timeout: TimeInterval = 5) async -> Proto.Frame? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let (_, f) = await nextFrame(timeout: deadline.timeIntervalSinceNow) else { return nil }
            if f.type == type && f.cmd == cmd { return f }
        }
        return nil
    }

    /// TYPE=3 has its own response slot, leaving file/audio frames with their existing consumer.
    /// Firmware correlates by TYPE/CMD; do not require it to echo the request SEQ.
    public func recordingExchange(_ command: UInt8, reply: UInt8, timeout: TimeInterval = 3) async throws -> [UInt8]? {
        try Task.checkCancellation()
        let token = try recordingReplies.begin(command: reply)
        defer { recordingReplies.end(token) }
        discardRecordingReply(reply)
        guard isConnected else { throw BLEError.notConnected }
        let seq = nextSeq()
        let request = Proto.Frame(seq: seq, data: [Proto.T.key, command])
        try sendRaw(Proto.buildFrame(Proto.T.key, command, seq: seq))
        if let event = RecordingDiagnosticEvent(phase: "tx", source: "AE21", frame: request) { onRecordingDiagnostic?(event) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            guard isConnected else { throw BLEError.notConnected }
            if let frame = recordingReplies.reply(for: token) { return frame.body }
            try await Task.sleep(for: .milliseconds(20))
        }
        if let event = RecordingDiagnosticEvent(phase: "timeout", source: "AE21", frame: request) { onRecordingDiagnostic?(event) }
        return nil
    }

    private func discardRecordingReply(_ command: UInt8) {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll { $0.frame.type == Proto.T.key && $0.frame.cmd == command }
    }

    public var parserStats: String {
        // 断连时会整只换掉 parsers，读的时候必须持锁，否则和换实例撞上就是数据竞争
        lock.lock()
        let lines = parsers.map { "\($0.key): CRC错\($0.value.crcErrors) 重同步\($0.value.resyncs)" }
        lock.unlock()
        return lines.sorted().joined(separator: "  ")
    }

    // MARK: - 内部

    private func clearDiscovered() { lock.lock(); discovered.removeAll(); lock.unlock() }

    private func snapshotDiscovered() -> [Discovered] {
        lock.lock(); defer { lock.unlock() }; return Array(discovered.values)
    }

    private func popPending() -> (source: String, frame: Proto.Frame)? {
        lock.lock(); defer { lock.unlock() }
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    /// 开扫描。**AllowDuplicates 是这里的重点**：默认同一台设备只上报一次，
    /// 长时间扫描会「看见一次就再也不响」，RSSI 也停在第一次的值上。
    /// 开了才拿得到持续广播，也才谈得上感知设备什么时候不见了。代价是耗电略增，
    /// 对插着电的 Mac 无所谓。
    ///
    /// 对 scan(seconds:) 的语义没有影响：它返回的是 discovered 这个按 peripheral 去重的字典，
    /// 重复上报只是把同一条记录的 RSSI 刷新成最新值，名单本身还是一台设备一条。
    private func beginScanning() {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func noteTimedScanBegan() {
        lock.lock(); timedScanDepth += 1; lock.unlock()
    }

    /// 返回 true 表示现在没人再需要扫描了，调用方可以 stopScan。
    private func noteTimedScanEnded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        timedScanDepth = max(0, timedScanDepth - 1)
        return timedScanDepth == 0 && advSinks.isEmpty
    }

    private func addSink(_ id: UUID, _ cont: AsyncStream<Discovered>.Continuation) {
        lock.lock(); advSinks[id] = cont; lock.unlock()
    }

    private func removeSink(_ id: UUID) {
        lock.lock()
        advSinks[id] = nil
        let idle = advSinks.isEmpty && timedScanDepth == 0
        lock.unlock()
        // stopScan 放在锁外：CoreBluetooth 会回到自己的队列，别在持锁时调外部对象
        if idle { central.stopScan() }
    }

    private func hasAdvSinks() -> Bool {
        lock.lock(); defer { lock.unlock() }; return !advSinks.isEmpty
    }

    /// 记一笔发现，并把当前订阅者拷出来。yield 必须在锁外做——消费者可能在
    /// 同一线程上顺手取消订阅，那会重入 removeSink，持锁调用就是自锁死。
    private func recordDiscovery(_ d: Discovered) -> [AsyncStream<Discovered>.Continuation] {
        lock.lock(); defer { lock.unlock() }
        discovered[ObjectIdentifier(d.peripheral)] = d
        return Array(advSinks.values)
    }

    /// 连接前把上一条连接的残留清干净。半帧缓冲尤其要清：
    /// 上次断在半帧上，残字节和这次的首字节拼起来会解出一个根本不存在的帧。
    ///
    /// 返回还没被叫醒的「等断干净」的人：走到这一步说明我们已经等过了（或者等超时了），
    /// 那条旧连接就此翻篇，不能把 disconnecting 一直挂着——挂着的话，它那个迟到的
    /// didDisconnect 会跑来收拾这条**新**连接。
    private func prepareForConnect(_ p: CBPeripheral) -> [() -> Void] {
        lock.lock(); defer { lock.unlock() }
        peripheral = p
        captureConnectionID = UUID()
        writeChar = nil
        notifyReady = 0
        pending.removeAll()
        notificationStatus.removeAll()
        wireBytes.removeAll()
        parsers = ["AE22": FrameParser(name: "AE22"), "AE23": FrameParser(name: "AE23")]
        disconnecting = nil
        let settle = settleWaiters; settleWaiters = []
        return settle
    }

    /// 主动断开的加锁段：立刻对外「已断开」，把 peripheral 挪到 disconnecting 等系统确认。
    private func beginDisconnect() -> CBPeripheral? {
        lock.lock(); defer { lock.unlock() }
        guard let p = peripheral else { return nil }
        peripheral = nil
        writeChar = nil
        notificationStatus.removeAll()
        disconnecting = p
        return p
    }

    /// 等上一条连接真的断干净。timeout 是兜底——系统偶尔不回 didDisconnect，
    /// 那也不能把调用方永远卡在这儿，宁可带着风险往下走。
    private func waitDisconnectSettled(timeout: TimeInterval) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let once = OnceResume(c)
            guard enqueueSettleWaiter({ once.fire() }) else { once.fire(); return }
            queue.asyncAfter(deadline: .now() + timeout) { once.fire() }
        }
    }

    /// 返回 false 表示压根没有断开中的连接，调用方直接过。
    private func enqueueSettleWaiter(_ f: @escaping () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard disconnecting != nil else { return false }
        settleWaiters.append(f)
        return true
    }

    /// 断连收尾。所有状态清理在锁内一次做完，所有回调在锁外发——
    /// 回调里上层很可能立刻发起重连，重入本对象。
    private func handleDisconnect(_ p: CBPeripheral, error: Error?) {
        lock.lock()
        guard peripheral === p else {
            // 不是当前这条连接。可能是我们主动断的那条终于确认了，也可能是更早的迟到回调。
            // 无论哪种都**不许碰当前连接的状态**——那是另一条命，清了它就等于凭空断线。
            var settle: [() -> Void] = []
            if disconnecting === p {
                disconnecting = nil
                settle = settleWaiters; settleWaiters = []
            }
            lock.unlock()
            for f in settle { f() }
            return
        }
        // 走到这儿说明我们没喊断它就断了 = 意外断连
        peripheral = nil
        writeChar = nil
        disconnecting = nil
        notifyReady = 0
        // 换新实例 = 丢掉半帧缓冲。已经解出来的完整帧（pending）**故意保留**：
        notificationStatus.removeAll()
        // 设备发完最后一帧就断开是常态，这些字节是真收到的，
        // 丢了会让刚下完的文件被判成「无应答」。
        parsers = ["AE22": FrameParser(name: "AE22"), "AE23": FrameParser(name: "AE23")]
        let cw = connectWaiter; connectWaiter = nil
        let dw = discoverWaiter; discoverWaiter = nil
        let w = waiter; waiter = nil
        let settle = settleWaiters; settleWaiters = []
        let handler = disconnectHandler
        lock.unlock()

        // 这两个 continuation 是真会「永远挂着」的：discoverWaiter 没有任何超时，
        // 断在服务发现中间就再也没人叫醒它。nextFrame 不在此列——它自带 deadline。
        w?.resume()
        cw?(.failure(BLEError.connectFailed(error?.localizedDescription ?? "连接已断开")))
        dw?(.failure(BLEError.notConnected))
        for f in settle { f() }
        handler?(error)
    }

    fileprivate func finishConnect(_ r: Result<Void, Error>, attempt: UUID? = nil) {
        lock.lock()
        if let attempt, attempt != connectAttempt { lock.unlock(); return }
        let w = connectWaiter; connectWaiter = nil; lock.unlock(); w?(r)
    }

    private func isCurrent(_ p: CBPeripheral) -> Bool {
        lock.lock(); defer { lock.unlock() }; return peripheral === p
    }

    fileprivate func finishDiscover(_ r: Result<Void, Error>, attempt: UUID? = nil) {
        lock.lock()
        if let attempt, attempt != discoverAttempt { lock.unlock(); return }
        let w = discoverWaiter; discoverWaiter = nil; lock.unlock(); w?(r)
    }
}

/// 只许 resume 一次的小盒子。等断开落定有两条唤醒路径（回调 / 超时兜底），
/// CheckedContinuation 被 resume 两次是直接崩溃，不是警告。
private final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Never>?
    init(_ c: CheckedContinuation<Void, Never>) { cont = c }
    func fire() {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume()
    }
}

extension BLEClient: CBCentralManagerDelegate {
    public func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let p = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
        p.delegate = self
        lock.lock()
        peripheral = p
        restoredIdentifier = p.identifier
        lock.unlock()
        onRestore?(p.identifier)
    }
    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state != .poweredOn {
            // iOS can invalidate the radio without delivering didDisconnect first.
            // A cached CBPeripheral/AE21 must not masquerade as a usable connection.
            lock.lock(); let current = peripheral; lock.unlock()
            if let current { handleDisconnect(current, error: BLEError.bluetoothUnavailable("蓝牙连接已失效，等待系统恢复")) }
            return
        }
        // 蓝牙关掉再打开，系统会把扫描一起丢掉。广播流的消费者还在等，得把扫描重新支起来。
        if c.state == .poweredOn, hasAdvSinks() { beginScanning() }
        if c.state == .poweredOn { onPoweredOn?() }
    }

    public func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                               advertisementData d: [String: Any], rssi: NSNumber) {
        let uuids = (d[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let byService = uuids.contains { $0.uuidString.lowercased().hasPrefix("ae20") }
        let name = (d[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "(无名)"
        let found = Discovered(peripheral: p, name: name,
                               rssi: rssi.intValue, byService: byService)
        for sink in recordDiscovery(found) { sink.yield(found) }
    }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        guard isCurrent(p) else { return }
        finishConnect(.success(()))
        onConnectAvailable?(p.identifier)
    }

    public func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard isCurrent(p) else { return }
        finishConnect(.failure(BLEError.connectFailed(error?.localizedDescription ?? "未知")))
    }

    public func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral,
                               error: Error?) {
        handleDisconnect(p, error: error)
    }
}

extension BLEClient: CBPeripheralDelegate {
    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard isCurrent(p) else { return }
        guard error == nil, let svc = p.services?.first(where: { $0.uuid.uuidString.lowercased().hasPrefix("ae20") }) else {
            finishDiscover(.failure(BLEError.missingCharacteristic("AE20 服务")))
            return
        }
        p.discoverCharacteristics(nil, for: svc)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard isCurrent(p) else { return }
        if let error { finishDiscover(.failure(error)); return }
        for c in s.characteristics ?? [] {
            let u = c.uuid.uuidString.lowercased()
            if u.hasPrefix("ae21") { writeChar = c }
            if u.hasPrefix("ae22") || u.hasPrefix("ae23") { p.setNotifyValue(true, for: c) }
        }
        guard writeChar != nil else {
            finishDiscover(.failure(BLEError.missingCharacteristic("AE21")))
            return
        }
        if requireKeyNotifications, !(s.characteristics ?? []).contains(where: { $0.uuid.uuidString.lowercased().hasPrefix("ae23") }) {
            finishDiscover(.failure(BLEError.missingCharacteristic("AE23")))
        }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard isCurrent(p) else { return }
        let uuid = c.uuid.uuidString.lowercased()
        guard uuid.hasPrefix("ae22") || uuid.hasPrefix("ae23") else { return }
        let source = uuid.hasPrefix("ae23") ? "AE23" : "AE22"
        lock.lock()
        guard peripheral === p else { lock.unlock(); return }
        notificationStatus[source] = error == nil && c.isNotifying
        let observer = notificationObserver
        let connection = captureConnectionID
        lock.unlock()
        observer?(BLENotificationObservation(connectionID: connection, source: source,
            isNotifying: c.isNotifying, error: error?.localizedDescription))
        guard source == "AE22" || requireKeyNotifications else { return }
        guard error == nil, c.isNotifying else {
            finishDiscover(.failure(BLEError.missingCharacteristic("\(source) 订阅失败")))
            return
        }
        lock.lock()
        let ready = notificationStatus["AE22"] == true && (!requireKeyNotifications || notificationStatus["AE23"] == true)
        lock.unlock()
        if ready { finishDiscover(.success(())) }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard isCurrent(p), error == nil else { return }
        guard let data = c.value else { return }
        let src = c.uuid.uuidString.lowercased().hasPrefix("ae23") ? "AE23" : "AE22"
        lock.lock()
        guard peripheral === p else { lock.unlock(); return }
        wireBytes[src, default: 0] += data.count
        let frames = parsers[src]!.feed([UInt8](data))
        liveAudioFrames += frames.filter { RecordingFramePolicy.isLiveAudio($0) }.count
        pending.append(contentsOf: frames.filter {
            !RecordingFramePolicy.isLiveAudio($0) && !recordingReplies.receive($0)
        }.map { (src, $0) })
        let diagnostic = recordingDiagnosticHandler
        let observer = frameObserver
        let connectionID = captureConnectionID
        lock.unlock()
        if let observer {
            let receivedAt = Date()
            let uptime = ProcessInfo.processInfo.systemUptime
            for frame in frames {
                observer(BLEFrameObservation(connectionID: connectionID, source: src, frame: frame,
                                             receivedAt: receivedAt, uptime: uptime))
            }
        }
        for frame in frames {
            if let event = RecordingDiagnosticEvent(phase: "rx", source: src, frame: frame) { diagnostic?(event) }
        }
    }

}
