import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components 3.0 as PlasmaComponents
import org.kde.kirigami as Kirigami

Kirigami.Page {
    id: root

    property int cfg_defaultPriority
    property int cfg_defaultPriorityDefault: 0
    property bool cfg_showPriority
    property bool cfg_showPriorityDefault: true
    property bool cfg_addToTop
    property bool cfg_addToTopDefault: false
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
    property bool cfg_syncEnabled
    property bool cfg_syncEnabledDefault: false
    property string cfg_managedCategories
    property string cfg_managedCategoriesDefault: '["Work","Personal","Education"]'
    property bool cfg_markdownExport
    property bool cfg_markdownExportDefault: false
    property string cfg_markdownPath
    property string cfg_markdownPathDefault: ""
    property bool cfg_enableIcsExport
    property bool cfg_enableIcsExportDefault: false
    property string cfg_listTitle
    property string cfg_listTitleDefault: "K Do it!"
    property var _parsedManagedCategories: {
        try {
            var v = JSON.parse(root.cfg_managedCategories || '["Work","Personal","Education"]')
            return Array.isArray(v) ? v : ["Work", "Personal", "Education"]
        } catch(e) {
            return ["Work", "Personal", "Education"]
        }
    }

    title: i18n("General")

    Kirigami.FormLayout {
        anchors.fill: parent

        PlasmaComponents.TextField {
            id: titleField
            Kirigami.FormData.label: i18n("Widget title:")
            implicitWidth: Kirigami.Units.gridUnit * 20
            placeholderText: i18n("My To-Do List")
            Component.onCompleted: text = root.cfg_listTitle
            onEditingFinished: root.cfg_listTitle = text.trim() || root.cfg_listTitleDefault
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
        }

        PlasmaComponents.TextField {
            id: pathField
            Kirigami.FormData.label: i18n("Tasks file:")
            implicitWidth: Kirigami.Units.gridUnit * 20
            placeholderText: i18n("Leave empty for local storage")
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
            Kirigami.FormData.label: i18n("Priority stripe:")
            text: i18n("Show color stripe on tasks")
            Binding on checked { value: root.cfg_showPriority }
            onToggled: root.cfg_showPriority = checked
        }

        PlasmaComponents.CheckBox {
            Kirigami.FormData.label: i18n("New tasks:")
            text: i18n("Add to top of list")
            Binding on checked { value: root.cfg_addToTop }
            onToggled: root.cfg_addToTop = checked
        }

        PlasmaComponents.CheckBox {
            Kirigami.FormData.label: i18n("Completed tasks:")
            text: i18n("Hide completed tasks")
            Binding on checked { value: root.cfg_hideCompleted }
            onToggled: root.cfg_hideCompleted = checked
        }

        PlasmaComponents.CheckBox {
            Kirigami.FormData.label: i18n("Due dates:")
            text: i18n("Show Today / Tomorrow / Yesterday")
            Binding on checked { value: root.cfg_verboseDates }
            onToggled: root.cfg_verboseDates = checked
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
        }

        PlasmaComponents.CheckBox {
            id: syncEnabledCheck
            Kirigami.FormData.label: i18n("Enable live sync:")
            Binding on checked { value: root.cfg_syncEnabled }
            onToggled: root.cfg_syncEnabled = checked
        }

        PlasmaComponents.Label {
            Kirigami.FormData.label: ""
            text: i18n("Check for external changes every 3 seconds (e.g. Syncthing, shared folder). Turn off on a single machine to save resources.")
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            color: Kirigami.Theme.disabledTextColor
            wrapMode: Text.WordWrap
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
        }

        PlasmaComponents.CheckBox {
            Kirigami.FormData.label: i18n("Markdown export:")
            text: i18n("Also write a Markdown file on every save")
            Binding on checked { value: root.cfg_markdownExport }
            onToggled: root.cfg_markdownExport = checked
        }

        PlasmaComponents.TextField {
            id: mdPathField
            Kirigami.FormData.label: i18n("Markdown file:")
            implicitWidth: Kirigami.Units.gridUnit * 20
            visible: root.cfg_markdownExport
            placeholderText: i18n("Leave empty to save next to JSON file")
            Component.onCompleted: text = root.cfg_markdownPath
            onEditingFinished: {
                var v = text.trim()
                if (v !== "" && v.indexOf("'") === -1 && v.indexOf("\n") === -1)
                    root.cfg_markdownPath = v
                else
                    text = root.cfg_markdownPath
            }
        }

        PlasmaComponents.Label {
            Kirigami.FormData.label: ""
            visible: root.cfg_markdownExport
            text: i18n("Uses Obsidian Tasks syntax (checkboxes, dates, priorities, categories). Leave empty to save next to the JSON file.")
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            color: Kirigami.Theme.disabledTextColor
            wrapMode: Text.WordWrap
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
        }

        PlasmaComponents.CheckBox {
            Kirigami.FormData.label: i18n("iCalendar export:")
            text: i18n("Export tasks to .ics calendar file")
            Binding on checked { value: root.cfg_enableIcsExport }
            onToggled: root.cfg_enableIcsExport = checked
        }

        PlasmaComponents.Label {
            Kirigami.FormData.label: ""
            visible: root.cfg_enableIcsExport
            text: i18n("Writes a .ics file with VTODO components alongside the JSON file. Calendar apps can subscribe to it for due-date reminders.")
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            color: Kirigami.Theme.disabledTextColor
            wrapMode: Text.WordWrap
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
        }

        Repeater {
            model: root._parsedManagedCategories
            delegate: RowLayout {
                Kirigami.FormData.label: index === 0 ? i18n("Categories:") : ""
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents.Label {
                    text: modelData
                    Layout.fillWidth: true
                    verticalAlignment: Text.AlignVCenter
                    Layout.minimumHeight: Kirigami.Units.gridUnit * 1.6
                }

                PlasmaComponents.Button {
                    icon.name: "edit-delete-symbolic"
                    flat: true
                    implicitWidth: Kirigami.Units.gridUnit * 1.6
                    implicitHeight: Kirigami.Units.gridUnit * 1.6
                    onClicked: {
                        var cats
                        try { cats = JSON.parse(root.cfg_managedCategories || '[]') }
                        catch(e) { cats = [] }
                        if (!Array.isArray(cats)) cats = []
                        var lower = modelData.toLowerCase()
                        for (var i = cats.length - 1; i >= 0; i--) {
                            if (typeof cats[i] === "string" && cats[i].toLowerCase() === lower) { cats.splice(i, 1); break }
                        }
                        root.cfg_managedCategories = JSON.stringify(cats)
                    }
                }
            }
        }

        RowLayout {
            Kirigami.FormData.label: i18n("Add:")
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents.TextField {
                id: newCategoryField
                Layout.fillWidth: true
                placeholderText: i18n("Category name...")
                onAccepted: addCatBtn.clicked()
            }

            PlasmaComponents.Button {
                id: addCatBtn
                text: i18n("Add")
                onClicked: {
                    var name = newCategoryField.text.trim()
                    if (name === "") return
                    var cats
                    try { cats = JSON.parse(root.cfg_managedCategories || '[]') }
                    catch(e) { cats = [] }
                    if (!Array.isArray(cats)) cats = []
                    var lower = name.toLowerCase()
                    for (var i = 0; i < cats.length; i++) {
                        if (typeof cats[i] === "string" && cats[i].toLowerCase() === lower) { newCategoryField.text = ""; return }
                    }
                    cats.push(name)
                    root.cfg_managedCategories = JSON.stringify(cats)
                    newCategoryField.text = ""
                }
            }
        }
    }
}
