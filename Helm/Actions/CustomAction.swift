import Foundation

struct CustomAction: Codable, Identifiable, Equatable
{
  var id: UUID
  var symbolName: String
  var name: String
  var commands: String

  init(id: UUID = UUID(),
       symbolName: String = "terminal",
       name: String = "",
       commands: String = "")
  {
    self.id = id
    self.symbolName = symbolName
    self.name = name
    self.commands = commands
  }
}

/// Manages loading and saving custom actions per repository.
class CustomActionsStore
{
  private static func key(for repoPath: String) -> String
  {
    "customActions-\(repoPath)"
  }

  static func actions(for repoPath: String) -> [CustomAction]
  {
    guard let data = UserDefaults.helm.data(
        forKey: key(for: repoPath))
    else { return [] }

    return (try? JSONDecoder().decode(
        [CustomAction].self, from: data)) ?? []
  }

  static func save(_ actions: [CustomAction],
                    for repoPath: String)
  {
    guard let data = try? JSONEncoder().encode(actions)
    else { return }

    UserDefaults.helm.set(data, forKey: key(for: repoPath))
  }
}
