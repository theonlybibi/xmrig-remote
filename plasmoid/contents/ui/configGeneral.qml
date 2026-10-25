import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    property alias cfg_serverUrl: urlField.text
    property alias cfg_token: tokenField.text
    property alias cfg_interval: intervalSpin.value
    property string cfg_layoutPosition: "bottom"
    property string cfg_layoutPositionDefault: "bottom"

    onCfg_layoutPositionChanged: posCombo.currentIndex = posCombo.indexOfValue(cfg_layoutPosition)

    Kirigami.FormLayout {
        Kirigami.InlineMessage {
            Kirigami.FormData.isSection: false
            Layout.fillWidth: true
            visible: /^http:\/\//i.test(urlField.text)
                     && !/^http:\/\/(localhost|127\.0\.0\.1|\[::1\])/i.test(urlField.text)
            type: Kirigami.MessageType.Warning
            text: i18n("Plain HTTP sends your token unencrypted. Use a VPN or an HTTPS reverse proxy.")
        }
        QQC2.TextField {
            id: urlField
            Kirigami.FormData.label: i18n("Server URL:")
            placeholderText: "http://192.168.1.10:8080"
        }
        QQC2.TextField {
            id: tokenField
            Kirigami.FormData.label: i18n("Token:")
            echoMode: TextInput.Password
        }
        QQC2.SpinBox {
            id: intervalSpin
            Kirigami.FormData.label: i18n("Refresh interval (s):")
            from: 2
            to: 300
        }
        QQC2.ComboBox {
            id: posCombo
            Kirigami.FormData.label: i18n("Info and button position:")
            textRole: "text"
            valueRole: "value"
            model: [
                { text: i18n("Bottom"), value: "bottom" },
                { text: i18n("Top"),    value: "top" },
                { text: i18n("Left"),   value: "left" },
                { text: i18n("Right"),  value: "right" }
            ]
            Component.onCompleted: currentIndex = indexOfValue(cfg_layoutPosition)
            onActivated: cfg_layoutPosition = currentValue
        }
    }
}
