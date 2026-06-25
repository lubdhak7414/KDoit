import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components 3.0 as PlasmaComponents
import org.kde.kirigami as Kirigami

ColumnLayout {
    spacing: Kirigami.Units.largeSpacing

    property string message: i18n("No tasks yet")
    property string iconSource: "view-task"

    Kirigami.Icon {
        source: iconSource
        implicitWidth: 64
        implicitHeight: 64
        opacity: 0.6
        Layout.alignment: Qt.AlignHCenter
    }

    PlasmaComponents.Label {
        text: message
        opacity: 0.7
        Layout.alignment: Qt.AlignHCenter
    }
}
