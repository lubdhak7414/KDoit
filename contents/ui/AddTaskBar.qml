import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components 3.0 as PlasmaComponents
import org.kde.kirigami as Kirigami

RowLayout {
    id: root

    signal addRequested(string title)

    spacing: Kirigami.Units.smallSpacing

    function commit() {
        var text = field.text.trim()
        if (text.length > 0) {
            root.addRequested(text)
            field.text = ""
        }
    }

    PlasmaComponents.TextField {
        id: field
        Layout.fillWidth: true
        placeholderText: i18n("New task...")
        onAccepted: root.commit()
        Keys.onEscapePressed: field.text = ""
    }

    PlasmaComponents.Button {
        icon.name: "list-add-symbolic"
        display: PlasmaComponents.AbstractButton.IconOnly
        text: i18n("Add task")
        onClicked: root.commit()
    }
}
