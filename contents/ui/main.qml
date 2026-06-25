import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.plasma.plasmoid
import org.kde.plasma.components 3.0 as PlasmaComponents
import org.kde.plasma.extras 2.0 as PlasmaExtras
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    property var navigationStack: []
    property var currentModel: taskModel
    property string currentTitle: i18n("My Tasks")
    property string searchText: ""
    property bool searchActive: false
    property var lastDeleted: null
    property var activeSublistTask: null
    property int _updateTrigger: 0

    property string categoryFilter: ""
    property var distinctCategories: []
    property var presetCategories: [
        { key: "work", label: i18n("Work") },
        { key: "personal", label: i18n("Personal") },
        { key: "shopping", label: i18n("Shopping") },
        { key: "health", label: i18n("Health") },
        { key: "finance", label: i18n("Finance") },
        { key: "education", label: i18n("Education") }
    ]
    property bool isFiltering: searchText.length > 0 || plasmoid.configuration.hideCompleted || categoryFilter !== ""

    property int visibleCount: {
        var _t = _updateTrigger
        var _h = plasmoid.configuration.hideCompleted
        var _s = searchText
        var _cf = categoryFilter
        var n = 0
        for (var i = 0; i < currentModel.count; i++) {
            var item = currentModel.get(i)
            if (matchesFilter(item.title, item.done, item.category || ""))
                n++
        }
        return n
    }

    preferredRepresentation: fullRepresentation

    Plasmoid.icon: "view-task"

    TaskModel {
        id: taskModel
        Component.onCompleted: root.updateDistinctCategories()
    }

    ListModel {
        id: sublistModel
    }

    function makeSublistRow(title, done) {
        return {
            title: title,
            done: done,
            priority: 0,
            category: "",
            createdAt: "",
            dueDate: "",
            sublist: []
        }
    }

    function syncSublist() {
        if (activeSublistTask === null)
            return
        var arr = []
        for (var i = 0; i < sublistModel.count; i++) {
            var t = sublistModel.get(i)
            arr.push({ title: t.title, done: t.done })
        }
        taskModel.setTaskProperty(activeSublistTask, "sublist", arr)
    }

    function dismissUndo() {
        lastDeleted = null
        undoMessage.visible = false
        undoTimer.stop()
    }

    function enterSublist(taskIndex) {
        if (taskIndex < 0 || taskIndex >= taskModel.count)
            return
        dismissUndo()
        navigationStack.push({ title: currentTitle, categoryFilter: categoryFilter })
        navigationStackChanged()
        categoryFilter = ""
        var task = taskModel.get(taskIndex)
        activeSublistTask = taskIndex
        sublistModel.clear()
        var sub = task.sublist
        for (var i = 0; i < sub.length; i++)
            sublistModel.append(makeSublistRow(sub[i].title, sub[i].done === true))
        currentTitle = task.title
        currentModel = sublistModel
    }

    function goBack() {
        if (navigationStack.length === 0)
            return
        dismissUndo()
        var entry = navigationStack.pop()
        navigationStackChanged()
        activeSublistTask = null
        currentModel = taskModel
        currentTitle = entry.title
        categoryFilter = entry.categoryFilter || ""
    }

    function isSublistView() {
        return currentModel === sublistModel
    }

    function addToCurrent(title) {
        if (isSublistView()) {
            sublistModel.append(makeSublistRow(title, false))
            syncSublist()
        } else {
            taskModel.addTask(title, plasmoid.configuration.defaultPriority)
        }
    }

    function deleteCurrent(index) {
        if (isSublistView()) {
            var st = sublistModel.get(index)
            lastDeleted = {
                index: index,
                task: { title: st.title, done: st.done, priority: 0, category: "", createdAt: "", dueDate: "", sublist: [] }
            }
            sublistModel.remove(index)
            syncSublist()
        } else {
            var t = taskModel.get(index)
            var subCopy = []
            for (var s = 0; s < t.sublist.length; s++)
                subCopy.push({ title: t.sublist[s].title, done: t.sublist[s].done === true })
            lastDeleted = {
                index: index,
                task: {
                    title: t.title, done: t.done, priority: t.priority,
                    category: t.category, createdAt: t.createdAt,
                    dueDate: t.dueDate, sublist: subCopy
                }
            }
            taskModel.removeTask(index)
        }
        _updateTrigger++
        updateDistinctCategories()
        undoTimer.restart()
        undoMessage.visible = true
    }

    function undoDelete() {
        if (lastDeleted === null)
            return
        if (isSublistView()) {
            sublistModel.insert(Math.min(lastDeleted.index, sublistModel.count),
                makeSublistRow(lastDeleted.task.title, lastDeleted.task.done))
            syncSublist()
        } else {
            taskModel.insertTask(lastDeleted.index, lastDeleted.task)
        }
        lastDeleted = null
        _updateTrigger++
        updateDistinctCategories()
        undoMessage.visible = false
        undoTimer.stop()
    }

    function sortTasks(mode) {
        dismissUndo()
        var rows = []
        for (var i = 0; i < currentModel.count; i++) {
            var t = currentModel.get(i)
            var sub = []
            for (var s = 0; s < t.sublist.length; s++)
                sub.push({ title: t.sublist[s].title, done: t.sublist[s].done === true })
            rows.push({
                title: t.title, done: t.done, priority: t.priority,
                category: t.category, createdAt: t.createdAt,
                dueDate: t.dueDate, sublist: sub
            })
        }
        rows.sort(function (a, b) {
            if (mode === "priority")
                return b.priority - a.priority || a.title.localeCompare(b.title)
            if (mode === "dueDate") {
                var ad = a.dueDate === "" ? "99999999" : a.dueDate
                var bd = b.dueDate === "" ? "99999999" : b.dueDate
                return ad < bd ? -1 : (ad > bd ? 1 : a.title.localeCompare(b.title))
            }
            if (mode === "title")
                return a.title.localeCompare(b.title)
            if (mode === "done")
                return (a.done === b.done) ? 0 : (a.done ? 1 : -1)
            return 0
        })
        currentModel.clear()
        for (var j = 0; j < rows.length; j++)
            currentModel.append(rows[j])
        if (isSublistView())
            syncSublist()
        else
            taskModel.save()
        _updateTrigger++
        updateDistinctCategories()
    }

    function categoryColor(cat) {
        if (cat === "")
            return "transparent"
        var hash = 5381
        for (var i = 0; i < cat.length; i++)
            hash = ((hash << 5) + hash + cat.charCodeAt(i)) & 0xFFFFFFFF
        var hue = (hash >>> 0) % 360
        return Qt.hsla(hue / 360, 0.7, 0.45, 1.0)
    }

    function categoryTextColor(cat) {
        if (cat === "")
            return "transparent"
        return "#ffffff"
    }

    function updateDistinctCategories() {
        var cats = {}
        for (var i = 0; i < taskModel.count; i++) {
            var c = taskModel.get(i).category
            if (c !== "")
                cats[c] = true
        }
        var arr = []
        for (var k in cats)
            arr.push(k)
        arr.sort()
        distinctCategories = arr
        if (categoryFilter !== "" && cats[categoryFilter] === undefined)
            categoryFilter = ""
    }

    function matchesFilter(title, done, cat) {
        if (plasmoid.configuration.hideCompleted && done)
            return false
        if (searchText.length > 0 && title.toLowerCase().indexOf(searchText.toLowerCase()) === -1)
            return false
        if (categoryFilter !== "" && cat !== categoryFilter)
            return false
        return true
    }

    Timer {
        id: undoTimer
        interval: 5000
        onTriggered: {
            undoMessage.visible = false
            lastDeleted = null
        }
    }

    fullRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 16
        Layout.minimumHeight: Kirigami.Units.gridUnit * 20
        Layout.preferredWidth: Kirigami.Units.gridUnit * 20
        Layout.preferredHeight: Kirigami.Units.gridUnit * 26

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents.Button {
                    icon.name: "go-previous-symbolic"
                    flat: true
                    display: PlasmaComponents.AbstractButton.IconOnly
                    text: i18n("Back")
                    visible: root.navigationStack.length > 0
                    onClicked: root.goBack()
                }

                PlasmaExtras.Heading {
                    level: 3
                    text: root.currentTitle
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

                PlasmaComponents.Button {
                    icon.name: "view-sort-symbolic"
                    flat: true
                    display: PlasmaComponents.AbstractButton.IconOnly
                    text: i18n("Sort")
                    onClicked: sortMenu.popup()

                    Controls.Menu {
                        id: sortMenu

                        Controls.MenuItem {
                            text: i18n("Priority")
                            onTriggered: root.sortTasks("priority")
                        }
                        Controls.MenuItem {
                            text: i18n("Due date")
                            onTriggered: root.sortTasks("dueDate")
                        }
                        Controls.MenuItem {
                            text: i18n("Name")
                            onTriggered: root.sortTasks("title")
                        }
                        Controls.MenuItem {
                            text: i18n("Completed last")
                            onTriggered: root.sortTasks("done")
                        }
                    }
                }

                PlasmaComponents.Button {
                    icon.name: "search-symbolic"
                    flat: true
                    checkable: true
                    display: PlasmaComponents.AbstractButton.IconOnly
                    text: i18n("Search")
                    checked: root.searchActive
                    onToggled: {
                        root.searchActive = checked
                        if (!checked)
                            searchField.text = ""
                    }
                }
            }

            PlasmaComponents.TextField {
                id: searchField
                Layout.fillWidth: true
                visible: root.searchActive
                placeholderText: i18n("Search tasks...")
                onTextChanged: root.searchText = text
                Keys.onEscapePressed: {
                    text = ""
                    root.searchActive = false
                }
            }

            Flow {
                Layout.fillWidth: true
                Layout.maximumHeight: Kirigami.Units.gridUnit * 2.7
                spacing: Kirigami.Units.smallSpacing / 2
                visible: root.distinctCategories.length > 0 && !root.isSublistView()
                clip: true

                Rectangle {
                    width: allLabel.implicitWidth + Kirigami.Units.largeSpacing
                    height: Kirigami.Units.gridUnit * 0.9
                    radius: height / 2
                    color: root.categoryFilter === "" ? Kirigami.Theme.highlightColor : Kirigami.Theme.alternateBackgroundColor
                    border.color: root.categoryFilter === "" ? Kirigami.Theme.highlightColor : Kirigami.Theme.disabledTextColor
                    border.width: 1

                    PlasmaComponents.Label {
                        id: allLabel
                        anchors.centerIn: parent
                        text: i18n("All")
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        color: root.categoryFilter === "" ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.textColor
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.categoryFilter = ""
                    }
                }

                Repeater {
                    model: root.distinctCategories
                    delegate: Rectangle {
                        required property string modelData
                        width: chipLabel.implicitWidth + Kirigami.Units.largeSpacing
                        height: Kirigami.Units.gridUnit * 0.9
                        radius: height / 2
                        color: root.categoryFilter === modelData ? root.categoryColor(modelData) : Kirigami.Theme.alternateBackgroundColor
                        border.color: root.categoryFilter === modelData ? root.categoryColor(modelData) : Kirigami.Theme.disabledTextColor
                        border.width: 1

                        PlasmaComponents.Label {
                            id: chipLabel
                            anchors.centerIn: parent
                            text: modelData
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            color: root.categoryFilter === modelData ? root.categoryTextColor(modelData) : Kirigami.Theme.textColor
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.categoryFilter = (root.categoryFilter === modelData ? "" : modelData)
                        }
                    }
                }
            }

            AddTaskBar {
                Layout.fillWidth: true
                onAddRequested: function (title) {
                    root.addToCurrent(title)
                }
            }

            Controls.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: root.visibleCount > 0
                clip: true
                contentWidth: availableWidth

                ListView {
                    id: taskList
                    model: root.currentModel
                    spacing: 0

                    property bool currentDragActive: false
                    property int dropTargetIndex: -1
                    property int dragSourceIndex: -1
                    property bool isDropping: false

                    signal resetAllTransforms()

                    interactive: !currentDragActive

                    displaced: Transition {
                        enabled: !taskList.isDropping
                        NumberAnimation { property: "y"; duration: 150; easing.type: Easing.OutCubic }
                    }

                    delegate: TaskDelegate {
                        matched: root.matchesFilter(title, done, category || "")
                        dragEnabled: !root.isFiltering && !root.isSublistView()
                        isSublistItem: root.isSublistView()
                        onTaskDeleted: root.deleteCurrent(index)
                        onDrillIntoSublist: function (taskIndex) {
                            if (!root.isSublistView())
                                root.enterSublist(taskIndex)
                        }
                        onTaskChanged: {
                            root._updateTrigger++
                            root.updateDistinctCategories()
                            if (root.isSublistView())
                                root.syncSublist()
                            else
                                taskModel.save()
                        }
                        onDragStarted: function (idx) {
                            taskList.dragSourceIndex = idx
                            taskList.dropTargetIndex = idx
                            taskList.currentDragActive = true
                        }
                        onDropTargetChanged: function (idx) {
                            taskList.dropTargetIndex = idx
                        }
                        onDropping: {
                            taskList.isDropping = true
                            taskList.resetAllTransforms()
                            dropResetTimer.restart()
                        }
                    }

                    Timer {
                        id: dropResetTimer
                        interval: 50
                        onTriggered: {
                            taskList.isDropping = false
                            taskList.currentDragActive = false
                            taskList.dragSourceIndex = -1
                            taskList.dropTargetIndex = -1
                        }
                    }
                }
            }

            EmptyState {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: root.visibleCount === 0
                message: root.currentModel.count > 0
                    ? (root.searchText.length > 0 || root.categoryFilter !== ""
                        ? i18n("No matching tasks")
                        : i18n("All tasks completed"))
                    : i18n("No tasks yet")
                iconSource: root.currentModel.count > 0 && (root.searchText.length > 0 || root.categoryFilter !== "")
                    ? "search-symbolic"
                    : "view-task"
            }

            Kirigami.InlineMessage {
                id: undoMessage
                Layout.fillWidth: true
                visible: false
                text: i18n("Task deleted")
                type: Kirigami.MessageType.Information
                actions: [
                    Kirigami.Action {
                        text: i18n("Undo")
                        onTriggered: root.undoDelete()
                    }
                ]
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents.Label {
                    text: i18np("%1 task", "%1 tasks", root.visibleCount)
                    opacity: 0.7
                    Layout.fillWidth: true
                }

                PlasmaComponents.Button {
                    text: i18n("Delete completed")
                    icon.name: "edit-clear-history-symbolic"
                    flat: true
                    visible: !root.isSublistView()
                    onClicked: {
                        taskModel.deleteCompleted()
                        root._updateTrigger++
                        root.updateDistinctCategories()
                    }
                }
            }
        }
    }
}
