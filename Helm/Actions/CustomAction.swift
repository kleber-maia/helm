import Foundation

indirect enum ActionJSONValue: Codable, Equatable
{
  case null, bool(Bool), string(String), integer(Int64), unsigned(UInt64)
  case number(Double), array([ActionJSONValue]), object([String: ActionJSONValue])
  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let v = try? c.decode(Bool.self) { self = .bool(v) }
    else if let v = try? c.decode(Int64.self) { self = .integer(v) }
    else if let v = try? c.decode(UInt64.self) { self = .unsigned(v) }
    else if let v = try? c.decode(Double.self) { self = .number(v) }
    else if let v = try? c.decode(String.self) { self = .string(v) }
    else if let v = try? c.decode([ActionJSONValue].self) { self = .array(v) }
    else { self = .object(try c.decode([String: ActionJSONValue].self)) }
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
      case .null: try c.encodeNil()
      case .bool(let v): try c.encode(v)
      case .string(let v): try c.encode(v)
      case .integer(let v): try c.encode(v)
      case .unsigned(let v): try c.encode(v)
      case .number(let v): try c.encode(v)
      case .array(let v): try c.encode(v)
      case .object(let v): try c.encode(v)
    }
  }
}

/// Unknown configuration remains attached to the original ID through editing.
struct CustomAction: Codable, Identifiable, Equatable
{
  var id: UUID
  var symbolName: String
  var name: String
  var commands: String
  var extraFields: [String: ActionJSONValue] = [:]

  init(id: UUID = UUID(), symbolName: String = "terminal",
       name: String = "", commands: String = "") {
    self.id = id; self.symbolName = symbolName
    self.name = name; self.commands = commands
  }
  private struct Key: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }
  private static let known = Set(["id", "symbolName", "name", "commands"])
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    id = try c.decode(UUID.self, forKey: Key("id"))
    symbolName = try c.decode(String.self, forKey: Key("symbolName"))
    name = try c.decode(String.self, forKey: Key("name"))
    commands = try c.decode(String.self, forKey: Key("commands"))
    for key in c.allKeys where !Self.known.contains(key.stringValue) {
      extraFields[key.stringValue] = try c.decode(ActionJSONValue.self, forKey: key)
    }
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Key.self)
    try c.encode(id, forKey: Key("id"))
    try c.encode(symbolName, forKey: Key("symbolName"))
    try c.encode(name, forKey: Key("name"))
    try c.encode(commands, forKey: Key("commands"))
    for (key, value) in extraFields where !Self.known.contains(key) {
      try c.encode(value, forKey: Key(key))
    }
  }
}

/// Definitions share storage; execution still uses the caller's active repoPath.
enum CustomActionsStore
{
  private static func store() throws -> ActionsPersistence {
    try ActionsPersistence(configuration: .current())
  }
  static func load(for repoPath: String) throws -> ActionsSnapshot {
    try store().load(repoPath)
  }
  static func save(_ actions: [CustomAction], for repoPath: String,
                   expectedRevision: String) throws -> ActionsSnapshot {
    try store().save(actions, at: repoPath, expected: expectedRevision)
  }
  static func recovery(for repoPath: String) throws -> ActionsRecovery {
    try store().recovery(repoPath)
  }
  static func recover(_ choice: ActionsRecovery.Choice, for repoPath: String,
                      expectedRevision: String, keepCurrent: Bool = false) throws -> ActionsSnapshot {
    try store().recover(choice, at: repoPath, expected: expectedRevision, keepCurrent: keepCurrent)
  }
}
