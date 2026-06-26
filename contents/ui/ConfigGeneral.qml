import QtQuick
import org.kde.plasma.components 3.0 as PlasmaComponents
import org.kde.kirigami as Kirigami

Kirigami.Page {
    id: root

    property int cfg_defaultPriority
    property bool cfg_hideCompleted
    property bool cfg_verboseDates
    property string cfg_tasksJson

    title: i18n("General")

    Kirigami.FormLayout {
        anchors.fill: parent

        PlasmaComponents.ComboBox {
            id: priorityCombo
            Kirigami.FormData.label: i18n("Default priority:")
            textRole: "text"
            valueRole: "value"
            model: [
                { text: i18n("Low"), value: 0 },
                { text: i18n("Medium"), value: 1 },
                { text: i18n("High"), value: 2 }
            ]
            Component.onCompleted: currentIndex = indexOfValue(root.cfg_defaultPriority)
            onActivated: root.cfg_defaultPriority = currentValue
        }

        PlasmaComponents.CheckBox {
            Kirigami.FormData.label: i18n("Completed tasks:")
            text: i18n("Hide completed tasks")
            checked: root.cfg_hideCompleted
            onToggled: root.cfg_hideCompleted = checked
        }

        PlasmaComponents.CheckBox {
            Kirigami.FormData.label: i18n("Due dates:")
            text: i18n("Show Today / Tomorrow / Yesterday")
            checked: root.cfg_verboseDates
            onToggled: root.cfg_verboseDates = checked
        }
    }
}
