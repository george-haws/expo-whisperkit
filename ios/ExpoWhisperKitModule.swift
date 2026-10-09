import ExpoModulesCore

public class ExpoWhisperKitModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoWhisperKit")

    Events("onChange")

    AsyncFunction("setValueAsync") { (value: String) in
      self.sendEvent("onChange", [
        "value": value
      ])
    }
  }
}
