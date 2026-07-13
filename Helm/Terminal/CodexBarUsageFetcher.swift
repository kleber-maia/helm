import Foundation

struct CodexBarUsageStatus
{
  let providerName: String
  let source: String?
  let session: CodexBarUsageWindow?
  let weekly: CodexBarUsageWindow?

  func withWeeklyPace(_ pace: Bool?) -> CodexBarUsageStatus
  {
    guard let pace,
          let weekly
    else { return self }

    return CodexBarUsageStatus(providerName: providerName,
                               source: source,
                               session: session,
                               weekly: weekly.withPace(pace))
  }
}

struct CodexBarUsageWindow
{
  let usedPercent: Double
  let windowMinutes: Int?
  let resetDescription: String?
  let resetsAt: Date?
  let remainingQuotaEnoughUntilReset: Bool?

  var hasEnoughRemainingQuota: Bool
  {
    remainingQuotaEnoughUntilReset ?? true
  }

  func withPace(_ pace: Bool) -> CodexBarUsageWindow
  {
    CodexBarUsageWindow(usedPercent: usedPercent,
                        windowMinutes: windowMinutes,
                        resetDescription: resetDescription,
                        resetsAt: resetsAt,
                        remainingQuotaEnoughUntilReset: pace)
  }
}

final class CodexBarUsageFetcher
{
  static let shared = CodexBarUsageFetcher()

  private let queue = DispatchQueue(label: "com.helm.codexbar-usage",
                                    qos: .utility)
  private let fileManager = FileManager.default
  private var cachedStatuses: [String: CodexBarUsageStatus] = [:]

  private init() {}

  func fetch(for agent: CodingAgent,
             completion: @escaping (CodexBarUsageStatus?) -> Void)
  {
    guard let providerID = agent.codexBarProviderID
    else {
      completion(nil)
      return
    }

    queue.async {
      let status = self.fetch(providerID: providerID,
                              source: agent.codexBarSource,
                              providerName: agent.displayName)

      DispatchQueue.main.async {
        completion(status)
      }
    }
  }

  private func fetch(providerID: String,
                     source: String?,
                     providerName: String) -> CodexBarUsageStatus?
  {
    var arguments = [
      "usage",
      "--provider", providerID,
      "--format", "json",
      "--json-only",
      "--no-color",
    ]
    if let source {
      arguments += ["--source", source]
    }

    guard let data = runCodexBar(arguments: arguments),
          let status = Self.decode(data: data,
                                   providerID: providerID,
                                   providerName: providerName)
    else { return cachedStatuses[cacheKey(providerID: providerID,
                                          source: source)] }

    let weeklyPace: Bool?
    if let weekly = status.weekly,
       weekly.remainingQuotaEnoughUntilReset == nil,
       providerID != Self.claudeProviderID {
      weeklyPace = fetchWeeklyPace(providerID: providerID, source: source)
    }
    else {
      weeklyPace = nil
    }
    let resolvedStatus = status.withWeeklyPace(weeklyPace)

    cachedStatuses[cacheKey(providerID: providerID, source: source)] =
        resolvedStatus
    return resolvedStatus
  }

  private func cacheKey(providerID: String,
                        source: String?) -> String
  {
    "\(providerID):\(source ?? "")"
  }

  private func fetchWeeklyPace(providerID: String,
                               source: String?) -> Bool?
  {
    var arguments = [
      "usage",
      "--provider", providerID,
      "--format", "text",
      "--no-color",
    ]
    if let source {
      arguments += ["--source", source]
    }

    guard let data = runCodexBar(arguments: arguments),
          let output = String(data: data, encoding: .utf8)
    else { return nil }

    return Self.weeklyPace(from: output)
  }

  private func runCodexBar(arguments: [String]) -> Data?
  {
    guard let executableURL = executableURL()
    else { return nil }

    let process = Process()
    let outputURL = temporaryFileURL()
    let errorURL = temporaryFileURL()

    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environmentWithCommonPaths()

    guard fileManager.createFile(atPath: outputURL.path, contents: nil),
          fileManager.createFile(atPath: errorURL.path, contents: nil),
          let outputHandle = try? FileHandle(forWritingTo: outputURL),
          let errorHandle = try? FileHandle(forWritingTo: errorURL)
    else { return nil }

    defer {
      outputHandle.closeFile()
      errorHandle.closeFile()
      try? fileManager.removeItem(at: outputURL)
      try? fileManager.removeItem(at: errorURL)
    }

    process.standardOutput = outputHandle
    process.standardError = errorHandle

    do {
      try process.run()
    }
    catch {
      return nil
    }

    let semaphore = DispatchSemaphore(value: 0)

    DispatchQueue.global(qos: .utility).async {
      process.waitUntilExit()
      semaphore.signal()
    }

    if semaphore.wait(timeout: .now() + Self.timeout) == .timedOut {
      process.terminate()
      return nil
    }

    guard process.terminationStatus == 0
    else { return nil }

    guard let data = try? Data(contentsOf: outputURL)
    else { return nil }

    return data
  }

  private func executableURL() -> URL?
  {
    for path in candidateExecutablePaths() {
      if fileManager.isExecutableFile(atPath: path) {
        return URL(fileURLWithPath: path)
      }
    }
    return nil
  }

  private func candidateExecutablePaths() -> [String]
  {
    let pathDirectories =
        ProcessInfo.processInfo.environment["PATH"]?
          .split(separator: ":")
          .map(String.init) ?? []

    let pathCandidates = pathDirectories.map { "\($0)/codexbar" }
    let commonCandidates = [
      "/opt/homebrew/bin/codexbar",
      "/usr/local/bin/codexbar",
      "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI",
    ]

    return pathCandidates + commonCandidates
  }

  private func environmentWithCommonPaths() -> [String: String]
  {
    var environment = ProcessInfo.processInfo.environment
    let currentPath = environment["PATH"] ?? ""
    let additions = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    environment["PATH"] = currentPath.isEmpty
        ? additions
        : "\(currentPath):\(additions)"
    return environment
  }

  private func temporaryFileURL() -> URL
  {
    fileManager.temporaryDirectory
      .appendingPathComponent("helm-codexbar-\(UUID().uuidString)")
  }

  private static let timeout: DispatchTimeInterval = .seconds(10)
  private static let claudeProviderID = "claude"
}

// MARK: - Decoding

private extension CodexBarUsageFetcher
{
  static func decode(data: Data,
                     providerID: String,
                     providerName: String) -> CodexBarUsageStatus?
  {
    guard let data = jsonPayloadData(from: data)
    else { return nil }

    let decoder = JSONDecoder()
    let payloads: [Payload]

    if let array = try? decoder.decode([Payload].self, from: data) {
      payloads = array
    }
    else if let payload = try? decoder.decode(Payload.self, from: data) {
      payloads = [payload]
    }
    else {
      return nil
    }

    let payload = payloads.first { $0.provider == providerID } ?? payloads.first

    guard let payload,
          let usage = payload.usage
    else { return nil }

    let session = usage.sessionWindow.map {
      payload.statusWindow(for: $0, usage: usage)
    }
    let weekly = usage.weeklyWindow.map {
      payload.statusWindow(for: $0, usage: usage)
    }

    guard session != nil || weekly != nil
    else { return nil }

    return CodexBarUsageStatus(providerName: providerName,
                               source: payload.source,
                               session: session,
                               weekly: weekly)
  }

  static func jsonPayloadData(from data: Data) -> Data?
  {
    guard let text = String(data: data, encoding: .utf8)
    else { return data }

    let lines = text.components(separatedBy: .newlines)

    for index in lines.indices {
      let candidate = lines[index...]
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)

      guard looksLikeJSONPayload(candidate)
      else { continue }

      return candidate.data(using: .utf8)
    }

    return nil
  }

  static func looksLikeJSONPayload(_ text: String) -> Bool
  {
    guard let first = text.first
    else { return false }

    if first == "{" {
      return true
    }
    if first == "[" {
      let remainder = text
        .dropFirst()
        .trimmingCharacters(in: .whitespacesAndNewlines)

      return remainder.first == "{" || remainder.first == "]"
    }
    return false
  }

  struct Payload: Decodable
  {
    let provider: String
    let source: String?
    let usage: Usage?
    let pace: PaceWindows?

    func statusWindow(for rateWindow: RateWindow,
                      usage: Usage) -> CodexBarUsageWindow
    {
      guard let pace = pace?.pace(for: rateWindow, usage: usage)
      else { return rateWindow.statusWindow }

      return rateWindow.statusWindow.withPace(pace)
    }
  }

  struct PaceWindows: Decodable
  {
    let primary: RateWindow.Pace?
    let secondary: RateWindow.Pace?

    func pace(for rateWindow: RateWindow,
              usage: Usage) -> Bool?
    {
      if usage.primary == rateWindow {
        return primary?.remainingQuotaEnoughUntilReset
      }
      if usage.secondary == rateWindow {
        return secondary?.remainingQuotaEnoughUntilReset
      }
      return nil
    }
  }

  struct Usage: Decodable
  {
    let primary: RateWindow?
    let secondary: RateWindow?
    let extraRateWindows: [ExtraRateWindow]?

    var sessionWindow: RateWindow?
    { classifiedWindows.session }

    var weeklyWindow: RateWindow?
    { classifiedWindows.weekly }

    /// Providers disagree on ordering: Claude/Codex put the short session
    /// window in `primary` and the weekly one in `secondary`, but others
    /// (e.g. Kimi) invert that. Classify by window length — the longer
    /// window is the weekly one — so the labels are correct regardless of
    /// position.
    private var classifiedWindows:
        (session: RateWindow?, weekly: RateWindow?)
    {
      let ranked = [primary, secondary]
          .compactMap { $0 }
          .sorted { $0.weeklyRankMinutes < $1.weeklyRankMinutes }

      switch ranked.count {
        case 0:
          return (extraRateWindows?.first { !$0.isWeekly }?.window,
                  extraRateWindows?.first { $0.isWeekly }?.window)
        case 1:
          let only = ranked[0]
          return only.weeklyRankMinutes >= RateWindow.weekThresholdMinutes
              ? (nil, only)
              : (only, nil)
        default:
          return (ranked.first, ranked.last)
      }
    }
  }

  struct ExtraRateWindow: Decodable
  {
    let id: String?
    let title: String?
    let window: RateWindow

    var isWeekly: Bool
    {
      let text = "\(id ?? "") \(title ?? "")".lowercased()
      return text.contains("weekly") ||
          window.windowMinutes.map { $0 >= Self.weekMinutes } == true
    }

    private static let weekMinutes = 7 * 24 * 60
  }

  struct RateWindow: Decodable, Equatable
  {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: String?
    let resetDescription: String?
    let remainingQuotaEnoughUntilReset: Bool?

    var statusWindow: CodexBarUsageWindow
    {
      CodexBarUsageWindow(usedPercent: usedPercent,
                          windowMinutes: windowMinutes,
                          resetDescription: resetDescription,
                          resetsAt: resetsAt.flatMap(Self.dateFormatter.date),
                          remainingQuotaEnoughUntilReset:
                            remainingQuotaEnoughUntilReset)
    }

    /// A comparable window length in minutes, used to tell the short
    /// session/rate window from the long weekly one. Falls back to the time
    /// until reset when the window length isn't provided (e.g. Kimi's weekly
    /// window omits `windowMinutes`).
    var weeklyRankMinutes: Double
    {
      if let windowMinutes = windowMinutes {
        return Double(windowMinutes)
      }
      if let resetsAt = resetsAt,
         let date = Self.dateFormatter.date(from: resetsAt) {
        return max(0, date.timeIntervalSinceNow / 60)
      }
      return 0
    }

    static let weekThresholdMinutes: Double = 24 * 60

    private enum CodingKeys: String, CodingKey
    {
      case usedPercent
      case windowMinutes
      case resetsAt
      case resetDescription
      case remainingQuotaEnoughUntilReset
      case lastsUntilReset
      case willLastUntilReset
      case usagePace
      case pace
    }

    init(from decoder: Decoder) throws
    {
      let container = try decoder.container(keyedBy: CodingKeys.self)

      usedPercent = try container.decode(Double.self, forKey: .usedPercent)
      windowMinutes = try container.decodeIfPresent(Int.self,
                                                    forKey: .windowMinutes)
      resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt)
      resetDescription = try container.decodeIfPresent(
        String.self,
        forKey: .resetDescription
      )
      var pace = try container.decodeIfPresent(
        Bool.self,
        forKey: .remainingQuotaEnoughUntilReset
      )
      if pace == nil {
        pace = try container.decodeIfPresent(Bool.self,
                                             forKey: .lastsUntilReset)
      }
      if pace == nil {
        pace = try container.decodeIfPresent(Bool.self,
                                             forKey: .willLastUntilReset)
      }
      if pace == nil {
        pace = try container.decodeIfPresent(Pace.self,
                                             forKey: .usagePace)?
          .remainingQuotaEnoughUntilReset
      }
      if pace == nil {
        pace = try container.decodeIfPresent(Pace.self,
                                             forKey: .pace)?
          .remainingQuotaEnoughUntilReset
      }
      remainingQuotaEnoughUntilReset = pace
    }

    struct Pace: Decodable
    {
      let remainingQuotaEnoughUntilReset: Bool?

      private enum CodingKeys: String, CodingKey
      {
        case remainingQuotaEnoughUntilReset
        case lastsUntilReset
        case willLastUntilReset
      }

      init(from decoder: Decoder) throws
      {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        var pace = try container.decodeIfPresent(
          Bool.self,
          forKey: .remainingQuotaEnoughUntilReset
        )
        if pace == nil {
          pace = try container.decodeIfPresent(Bool.self,
                                               forKey: .lastsUntilReset)
        }
        if pace == nil {
          pace = try container.decodeIfPresent(Bool.self,
                                               forKey: .willLastUntilReset)
        }
        remainingQuotaEnoughUntilReset = pace
      }
    }

    private static let dateFormatter = ISO8601DateFormatter()
  }

  static func weeklyPace(from text: String) -> Bool?
  {
    guard let line = text
      .components(separatedBy: .newlines)
      .first(where: { $0.lowercased().hasPrefix("pace:") })
    else { return nil }

    let lowercased = line.lowercased()

    if lowercased.contains("lasts until reset") ||
       lowercased.contains("on pace") ||
       lowercased.contains("in reserve") {
      return true
    }

    if lowercased.contains("exhaust") ||
       lowercased.contains("over pace") ||
       lowercased.contains("not last") {
      return false
    }

    return nil
  }
}
