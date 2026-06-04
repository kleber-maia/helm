import Foundation

struct CustomActionsDialog: SheetDialog
{
  typealias ContentView = CustomActionsPanel

  let actions: [CustomAction]

  var acceptButtonTitle: UIString { .ok }

  func createModel() -> CustomActionsModel?
  {
    CustomActionsModel(actions: actions)
  }
}
