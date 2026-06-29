import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.plasma.plasmoid
import org.kde.plasma.components 3.0 as PlasmaComponents
import org.kde.plasma.extras 2.0 as PlasmaExtras
import org.kde.plasma.plasma5support as Plasma5Support
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
    property var managedCategories: []
    property var _prevManagedCategories: []
    property bool _categoriesInitialized: false
    property bool isFiltering: searchText.length > 0 || plasmoid.configuration.hideCompleted || categoryFilter !== ""

    property var selectedIndices: ({})
    property int _lastClickedIndex: -1
    property string _lastMtime: "0"
    property string _activeSublistUuid: ""
    property bool _undoVisible: false
    property bool _skipNextPoll: false

    function toggleSelect(index) {
        if (isSublistView())
            return
        var copy = Object.assign({}, selectedIndices)
        if (copy[index])
            delete copy[index]
        else
            copy[index] = true
        selectedIndices = copy
        _lastClickedIndex = index
    }

    function rangeSelect(index) {
        if (isSublistView())
            return
        if (_lastClickedIndex < 0) {
            toggleSelect(index)
            return
        }
        var lo = Math.min(_lastClickedIndex, index)
        var hi = Math.max(_lastClickedIndex, index)
        var copy = Object.assign({}, selectedIndices)
        for (var i = lo; i <= hi; i++) {
            if (i < 0 || i >= currentModel.count)
                continue
            var it = currentModel.get(i)
            if (matchesFilter(it.title, it.done, it.category || ""))
                copy[i] = true
        }
        selectedIndices = copy
        _lastClickedIndex = index
    }

    function selectOnly(index) {
        if (isSublistView())
            return
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
        if (isSublistView())
            return
        var indices = Object.keys(selectedIndices).map(Number)
        if (indices.length === 0)
            return
        var removed = []
        for (var i = 0; i < indices.length; i++) {
            var idx = indices[i]
            if (idx >= 0 && idx < currentModel.count) {
                var t = currentModel.get(idx)
                var subCopy = taskModel.normalizeSublist(t.sublist)
                removed.push({ index: idx, task: {
                    uuid: t.uuid,
                    title: t.title, done: t.done, priority: t.priority,
                    category: t.category, createdAt: t.createdAt,
                    modifiedAt: t.modifiedAt,
                    dueDate: t.dueDate, sublist: subCopy
                }})
            }
        }
        currentModel.removeTasks(indices)
        clearSelection()
        _updateTrigger++
        updateDistinctCategories()
        lastDeleted = { type: "multi", items: removed }
        undoTimer.restart()
        _undoVisible = true
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

    Plasma5Support.DataSource {
        id: writer
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source)
            if (data["exit code"] !== 0)
                console.warn("KDoit save failed:", data.stderr || data.stdout)
        }
        function run(cmd) { connectSource(cmd) }
    }

    Plasma5Support.DataSource {
        id: fileReader
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source)
            taskModel.loadFromShell(data["exit code"] === 0 ? data.stdout : "")
        }
        function run(path) { connectSource("cat '" + path.replace(/'/g, "'\\''") + "'") }
    }

    Plasma5Support.DataSource {
        id: mtimeChecker
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source)
            if (root._skipNextPoll) {
                root._skipNextPoll = false
                return
            }
            if (data["exit code"] === 0) {
                var mtime = data.stdout.trim()
                if (mtime !== root._lastMtime) {
                    root._lastMtime = mtime
                    var path = plasmoid.configuration.storagePath
                    if (path !== "") fileReader.run(path)
                }
            }
        }
        function check(path) { connectSource("stat -c %Y '" + path.replace(/'/g, "'\\''") + "'") }
    }

    Plasma5Support.DataSource {
        id: mdReader
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source)
            if (data["exit code"] === 0) {
                var result = taskModel.importFromMarkdown(data.stdout)
                if (result.imported > 0 || result.updated > 0) {
                    root._updateTrigger++
                    root.updateDistinctCategories()
                    root._skipNextPoll = true
                }
            } else {
                console.warn("KDoit markdown import: file read failed")
            }
        }
        function run(path) { connectSource("cat '" + path.replace(/'/g, "'\\''") + "'") }
    }

    Timer {
        id: fileWatcher
        interval: 3000
        repeat: true
        running: plasmoid.configuration.syncEnabled
        onTriggered: {
            var path = plasmoid.configuration.storagePath
            if (path !== "") mtimeChecker.check(path)
        }
    }

    TaskModel {
        id: taskModel
        onRunShellCmd: function(cmd) { writer.run(cmd) }
        onRequestFileLoad: function(path) { fileReader.run(path) }
        onModelReloaded: {
            root.updateDistinctCategories()
            root._updateTrigger++
            root.dismissUndo()
            // If the user is viewing a sublist, refresh it from the updated task model
            // so remote sublist changes don't get overwritten by the stale snapshot.
            // Use UUID lookup — deletion propagation may have shifted model indices.
            if (root.isSublistView() && root._activeSublistUuid !== "") {
                var newIdx = -1
                for (var n = 0; n < taskModel.count; n++) {
                    if (taskModel.get(n).uuid === root._activeSublistUuid) { newIdx = n; break }
                }
                if (newIdx < 0) {
                    root.goBack()
                } else {
                    root.activeSublistTask = newIdx
                    var task = taskModel.get(newIdx)
                    var sub = taskModel.normalizeSublist(task.sublist)
                    sublistModel.clear()
                    for (var i = 0; i < sub.length; i++)
                        sublistModel.append(root.makeSublistRow(sub[i].uuid, sub[i].title, sub[i].done === true))
                }
            }
        }
        Component.onCompleted: root.updateDistinctCategories()
    }

    Connections {
        target: plasmoid.configuration
        function onManagedCategoriesChanged() {
            root._onManagedCategoriesChanged()
        }
    }

    ListModel {
        id: sublistModel
    }

    function makeSublistRow(uuid, title, done) {
        return {
            uuid: uuid,
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
        if (_activeSublistUuid === "")
            return
        // Re-derive the index by UUID — remote deletions may have shifted indices.
        var syncIdx = -1
        for (var n = 0; n < taskModel.count; n++) {
            if (taskModel.get(n).uuid === _activeSublistUuid) { syncIdx = n; break }
        }
        if (syncIdx < 0) return
        activeSublistTask = syncIdx
        var arr = []
        for (var i = 0; i < sublistModel.count; i++) {
            var t = sublistModel.get(i)
            arr.push({ uuid: t.uuid || taskModel.newUuid(), title: t.title, done: t.done })
        }
        taskModel.setTaskProperty(syncIdx, "sublist", arr)
    }

    function dismissUndo() {
        lastDeleted = null
        _undoVisible = false
        undoTimer.stop()
    }

    function enterSublist(taskIndex) {
        if (taskIndex < 0 || taskIndex >= taskModel.count)
            return
        dismissUndo()
        clearSelection()
        navigationStack.push({ title: currentTitle, categoryFilter: categoryFilter })
        navigationStackChanged()
        categoryFilter = ""
        var task = taskModel.get(taskIndex)
        activeSublistTask = taskIndex
        _activeSublistUuid = task.uuid
        sublistModel.clear()
        var sub = taskModel.normalizeSublist(task.sublist)
        for (var i = 0; i < sub.length; i++)
            sublistModel.append(makeSublistRow(sub[i].uuid, sub[i].title, sub[i].done === true))
        currentTitle = task.title
        currentModel = sublistModel
    }

    function goBack() {
        if (navigationStack.length === 0)
            return
        dismissUndo()
        clearSelection()
        var entry = navigationStack.pop()
        navigationStackChanged()
        activeSublistTask = null
        _activeSublistUuid = ""
        currentModel = taskModel
        currentTitle = entry.title
        categoryFilter = entry.categoryFilter || ""
    }

    function isSublistView() {
        return currentModel === sublistModel
    }

    function addToCurrent(title) {
        if (isSublistView()) {
            if (plasmoid.configuration.addToTop)
                sublistModel.insert(0, makeSublistRow(taskModel.newUuid(), title, false))
            else
                sublistModel.append(makeSublistRow(taskModel.newUuid(), title, false))
            syncSublist()
        } else {
            taskModel.addTask(title, plasmoid.configuration.defaultPriority, plasmoid.configuration.addToTop)
        }
    }

    function deleteCurrent(index) {
        if (isSublistView()) {
            var st = sublistModel.get(index)
            lastDeleted = {
                index: index,
                task: { uuid: st.uuid, title: st.title, done: st.done, priority: 0, category: "", createdAt: "", dueDate: "", sublist: [] }
            }
            sublistModel.remove(index)
            syncSublist()
        } else {
            var t = taskModel.get(index)
            var subCopy = taskModel.normalizeSublist(t.sublist)
            lastDeleted = {
                index: index,
                task: {
                    uuid: t.uuid,
                    title: t.title, done: t.done, priority: t.priority,
                    category: t.category, createdAt: t.createdAt,
                    modifiedAt: t.modifiedAt,
                    dueDate: t.dueDate, sublist: subCopy
                }
            }
            taskModel.removeTask(index)
        }
        clearSelection()
        _updateTrigger++
        updateDistinctCategories()
        undoTimer.restart()
        _undoVisible = true
    }

    function undoDelete() {
        if (lastDeleted === null)
            return
        if (lastDeleted.type === "multi") {
            var items = lastDeleted.items.slice().sort(function(a, b) { return a.index - b.index })
            for (var i = 0; i < items.length; i++) {
                taskModel.insertTask(items[i].index, items[i].task)
            }
        } else if (isSublistView()) {
            sublistModel.insert(Math.min(lastDeleted.index, sublistModel.count),
                makeSublistRow(lastDeleted.task.uuid || taskModel.newUuid(), lastDeleted.task.title, lastDeleted.task.done))
            syncSublist()
        } else {
            taskModel.insertTask(lastDeleted.index, lastDeleted.task)
        }
        lastDeleted = null
        clearSelection()
        _updateTrigger++
        updateDistinctCategories()
        _undoVisible = false
        undoTimer.stop()
    }

    function sortTasks(mode) {
        dismissUndo()
        var rows = []
        for (var i = 0; i < currentModel.count; i++) {
            var t = currentModel.get(i)
            var sub = taskModel.normalizeSublist(t.sublist)
            rows.push({
                uuid: t.uuid,
                title: t.title, done: t.done, priority: t.priority,
                category: t.category, createdAt: t.createdAt,
                modifiedAt: t.modifiedAt || "",
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
        clearSelection()
        _updateTrigger++
        updateDistinctCategories()
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
        if (!isSublistView() && plasmoid.configuration.hideCompleted && done)
            return false
        if (searchText.length > 0 && title.toLowerCase().indexOf(searchText.toLowerCase()) === -1)
            return false
        if (categoryFilter !== "" && cat !== categoryFilter)
            return false
        return true
    }

    function _parseManagedCategories() {
        try {
            return JSON.parse(plasmoid.configuration.managedCategories || '["Work","Personal","Education"]')
        } catch(e) {
            return ["Work", "Personal", "Education"]
        }
    }

    function addManagedCategory(name) {
        name = name.trim()
        if (name === "") return
        var cats = _parseManagedCategories()
        var lower = name.toLowerCase()
        for (var i = 0; i < cats.length; i++) {
            if (cats[i].toLowerCase() === lower) return
        }
        cats.push(name)
        plasmoid.configuration.managedCategories = JSON.stringify(cats)
    }

    function removeManagedCategory(name) {
        var cats = _parseManagedCategories()
        var lower = name.toLowerCase()
        for (var i = cats.length - 1; i >= 0; i--) {
            if (cats[i].toLowerCase() === lower) { cats.splice(i, 1); break }
        }
        plasmoid.configuration.managedCategories = JSON.stringify(cats)
    }

    function _onManagedCategoriesChanged() {
        var newCats = _parseManagedCategories()
        if (!_categoriesInitialized) {
            _prevManagedCategories = newCats.slice()
            _categoriesInitialized = true
            managedCategories = newCats
            return
        }
        var removed = []
        for (var i = 0; i < _prevManagedCategories.length; i++) {
            var found = false
            for (var j = 0; j < newCats.length; j++) {
                if (newCats[j].toLowerCase() === _prevManagedCategories[i].toLowerCase()) {
                    found = true; break
                }
            }
            if (!found) removed.push(_prevManagedCategories[i])
        }
        for (var k = 0; k < removed.length; k++) {
            taskModel.clearCategoryFromAll(removed[k])
        }
        if (removed.length > 0) {
            _updateTrigger++
            updateDistinctCategories()
        }
        _prevManagedCategories = newCats.slice()
        managedCategories = newCats
    }

    function _initManagedCategories() {
        var cats = _parseManagedCategories()
        cats = taskModel.migrateCategoryCase(cats)
        plasmoid.configuration.managedCategories = JSON.stringify(cats)
        managedCategories = cats
        _prevManagedCategories = cats.slice()
        _categoriesInitialized = true
    }

    Timer {
        id: undoTimer
        interval: 5000
        onTriggered: {
            root._undoVisible = false
            lastDeleted = null
        }
    }

    Component.onCompleted: {
        root._initManagedCategories()
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
                    model: [i18n("All")].concat(root.distinctCategories)
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
                visible: root._undoVisible
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
                    color: Qt.alpha(Kirigami.Theme.textColor, 0.7)
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
                    icon.name: "edit-clear-history-symbolic"
                    icon.color: Kirigami.Theme.highlightColor
                    flat: true
                    display: PlasmaComponents.AbstractButton.IconOnly
                    visible: !root.isSublistView() && root.selectedCount() === 0
                    onClicked: {
                        taskModel.deleteCompleted()
                        root.clearSelection()
                        root._updateTrigger++
                        root.updateDistinctCategories()
                    }
                    Controls.ToolTip {
                        text: i18n("Delete Completed")
                        delay: Kirigami.Units.toolTipDelay
                    }
                }
            }
        }
    }
}
