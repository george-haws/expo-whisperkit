import ExpoModulesCore
import WhisperKit

public class ExpoWhisperKitModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoWhisperKit")

    Function("deviceName") { () -> String in
      WhisperKit.deviceName()
    }
  }
}
