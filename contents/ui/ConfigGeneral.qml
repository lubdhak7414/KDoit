import QtQuick
import org.kde.plasma.components 3.0 as PlasmaComponents
import org.kde.kirigami as Kirigami

Kirigami.Page {
    id: root

    property int cfg_defaultPriority
    property int cfg_defaultPriorityDefault: 1
    property bool cfg_hideCompleted
    property bool cfg_hideCompletedDefault: false
    property bool cfg_verboseDates
    property bool cfg_verboseDatesDefault: true
    property string cfg_tasksJson
    property string cfg_tasksJsonDefault: "[]"
    property string cfg_storagePath
    property string cfg_storagePathDefault: ""
    property bool cfg_migratedToFile
    property bool cfg_migratedToFileDefault: false

    title: i18n("General")

    Kirigami.FormLayout {
        anchors.fill: parent

        PlasmaComponents.TextField {
            id: pathField
            Kirigami.FormData.label: i18n("Tasks file:")
            implicitWidth: Kirigami.Units.gridUnit * 20
            placeholderText: i18n("e.g. /home/user/.local/share/kdoit/tasks.json")
            Component.onCompleted: text = root.cfg_storagePath
            onEditingFinished: {
                var v = text.trim()
                if (v !== "" && v.indexOf("'") === -1 && v.indexOf("\n") === -1)
                    root.cfg_storagePath = v
                else
                    text = root.cfg_storagePath
            }
        }

        PlasmaComponents.Label {
            Kirigami.FormData.label: ""
            text: i18n("Point this at a synced folder to share tasks across machines.")
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            color: Kirigami.Theme.disabledTextColor
            wrapMode: Text.WordWrap
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
        }

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
