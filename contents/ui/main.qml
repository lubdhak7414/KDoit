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

    property var selectedIndices: ({})
    property int _lastClickedIndex: -1

    function toggleSelect(index) {
        var copy = Object.assign({}, selectedIndices)
        if (copy[index])
            delete copy[index]
        else
            copy[index] = true
        selectedIndices = copy
        _lastClickedIndex = index
    }

    function rangeSelect(index) {
        if (_lastClickedIndex < 0) {
            toggleSelect(index)
            return
        }
        var lo = Math.min(_lastClickedIndex, index)
        var hi = Math.max(_lastClickedIndex, index)
        var copy = Object.assign({}, selectedIndices)
        for (var i = lo; i <= hi; i++)
            copy[i] = true
        selectedIndices = copy
        _lastClickedIndex = index
    }

    function selectOnly(index) {
        var keys = Object.keys(selectedIndices)
        if (keys.length === 1 && parseInt(keys[0]) === index) {
            clearSelection()
            return
        }
        var copy = {}
        copy[index] = true
        selectedIndices = copy
        _lastClickedIndex = index
    }

    function clearSelection() {
        selectedIndices = {}
        _lastClickedIndex = -1
    }

    function selectedCount() {
        return Object.keys(selectedIndices).length
    }

    function deleteSelected() {
        var indices = Object.keys(selectedIndices).map(Number)
        if (indices.length === 0)
            return
        var removed = []
        for (var i = 0; i < indices.length; i++) {
            var idx = indices[i]
            if (idx >= 0 && idx < currentModel.count) {
                var t = currentModel.get(idx)
                removed.push({ index: idx, task: JSON.parse(JSON.stringify(t)) })
            }
        }
        currentModel.removeTasks(indices)
        clearSelection()
        _updateTrigger++
        updateDistinctCategories()
        lastDeleted = { type: "multi", items: removed }
        undoTimer.restart()
        undoMessage.visible = true
    }

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
        if (typeof undoMessage !== "undefined")
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
        if (lastDeleted.type === "multi") {
            var items = lastDeleted.items
            for (var i = 0; i < items.length; i++) {
                taskModel.insertTask(items[i].index, items[i].task)
            }
        } else if (isSublistView()) {
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
            if (mode === "createdAt") {
                var ac = a.createdAt === "" ? "00000000" : a.createdAt
                var bc = b.createdAt === "" ? "00000000" : b.createdAt
                return ac < bc ? -1 : (ac > bc ? 1 : a.title.localeCompare(b.title))
            }
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

    property var _categoryHues: [
        { h: 0,   s: 0.75, lDark: 0.49, lLight: 0.69 },
        { h: 30,  s: 0.65, lDark: 0.38, lLight: 0.53 },
        { h: 50,  s: 0.65, lDark: 0.30, lLight: 0.42 },
        { h: 150, s: 0.65, lDark: 0.30, lLight: 0.41 },
        { h: 185, s: 0.70, lDark: 0.30, lLight: 0.42 },
        { h: 218, s: 0.80, lDark: 0.51, lLight: 0.67 },
        { h: 270, s: 0.70, lDark: 0.58, lLight: 0.71 },
        { h: 330, s: 0.75, lDark: 0.47, lLight: 0.68 }
    ]

    function _hashCategory(cat) {
        var hash = 5381
        for (var i = 0; i < cat.length; i++)
            hash = ((hash << 5) + hash + cat.charCodeAt(i)) & 0xFFFFFFFF
        return (hash >>> 0) % _categoryHues.length
    }

    function categoryColor(cat) {
        if (cat === "")
            return "transparent"
        var entry = _categoryHues[_hashCategory(cat)]
        var bgLuma = Kirigami.ColorUtils.grayForColor(Kirigami.Theme.backgroundColor)
        var lightness = bgLuma < 0.5 ? entry.lDark : entry.lLight
        return Qt.hsla(entry.h / 360, entry.s, lightness, 1.0)
    }

    function categoryTextColor(cat) {
        if (cat === "")
            return "transparent"
        return Kirigami.Theme.textColor
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

                PlasmaComponents.ComboBox {
                    id: categoryCombo
                    visible: root.distinctCategories.length > 0 && !root.isSublistView()
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 6
                    model: [i18n("All")].concat(root.distinctCategories.map(function(c) { return c }))
                    currentIndex: {
                        if (root.categoryFilter === "") return 0
                        var idx = root.distinctCategories.indexOf(root.categoryFilter)
                        return idx >= 0 ? idx + 1 : 0
                    }
                    onActivated: function(index) {
                        if (index === 0)
                            root.categoryFilter = ""
                        else
                            root.categoryFilter = root.distinctCategories[index - 1]
                    }
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
                        Controls.MenuItem {
                            text: i18n("Created")
                            onTriggered: root.sortTasks("createdAt")
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

            AddTaskBar {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.largeSpacing
                onAddRequested: function (title) {
                    root.addToCurrent(title)
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents.Label {
                    text: root.selectedCount() > 0
                        ? i18np("%1 selected", "%1 selected", root.selectedCount())
                        : i18np("%1 task", "%1 tasks", root.visibleCount)
                    opacity: 0.7
                    Layout.fillWidth: true
                }

                PlasmaComponents.Button {
                    text: i18n("Delete selected")
                    icon.name: "edit-delete-symbolic"
                    flat: true
                    visible: root.selectedCount() > 0
                    onClicked: root.deleteSelected()
                }

                PlasmaComponents.Button {
                    text: i18n("Delete completed")
                    icon.name: "edit-clear-history-symbolic"
                    flat: true
                    visible: !root.isSublistView() && root.selectedCount() === 0
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
