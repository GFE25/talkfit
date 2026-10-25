import UIKit
import Capacitor

/// アプリ内に置いたプラグイン（TalkFitVoice）を Capacitor に登録する。
/// Main.storyboard の画面がこのクラスを使う。
class MainViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(TalkFitVoicePlugin())
    }
}
