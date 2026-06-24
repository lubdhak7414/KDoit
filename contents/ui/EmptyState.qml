import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components 3.0 as PlasmaComponents
import org.kde.kirigami as Kirigami

ColumnLayout {
    spacing: Kirigami.Units.largeSpacing

    Kirigami.Icon {
        source: "view-task"
        implicitWidth: 64
        implicitHeight: 64
        opacity: 0.6
        Layout.alignment: Qt.AlignHCenter
    }

    PlasmaComponents.Label {
        text: i18n("No tasks yet")
        opacity: 0.7
        Layout.alignment: Qt.AlignHCenter
    }
}
