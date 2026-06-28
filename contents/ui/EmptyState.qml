import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components 3.0 as PlasmaComponents
import org.kde.kirigami as Kirigami

Item {
    id: root

    property string message: i18n("No tasks yet")
    property string iconSource: "view-task"

    ColumnLayout {
        anchors.centerIn: parent
        spacing: Kirigami.Units.largeSpacing

        Kirigami.Icon {
            source: root.iconSource
            implicitWidth: Kirigami.Units.iconSizes.huge
            implicitHeight: Kirigami.Units.iconSizes.huge
            color: Qt.alpha(Kirigami.Theme.textColor, 0.6)
            Layout.alignment: Qt.AlignHCenter
        }

        PlasmaComponents.Label {
            text: root.message
            color: Qt.alpha(Kirigami.Theme.textColor, 0.7)
            Layout.alignment: Qt.AlignHCenter
        }
    }
}
